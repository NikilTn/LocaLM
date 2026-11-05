import Foundation

/// Bundled tool-use evaluation (Resources/EvalCases.json), run on the phone with the real system prompt,
/// tool schemas, prompt format, parser, and date resolver. Tools are never executed.
struct EvalCase: Decodable {
    struct Turn: Decodable {
        var role: String
        var content: String?
        var calls: [Call]?
    }
    struct Call: Decodable {
        var name: String
        var args: [[String]]
    }
    /// A case passes if ANY expectation matches. `tool == nil` means "no tool call".
    struct Expectation: Decodable {
        var tool: String?
        var toolCount: Int?
        var titleAny: [String]?
        var whenAll: [String]?
        var whenAbsent: Bool?
        var whenResolves: Bool?
        /// Generic argument checks: value contains any / all of the substrings (case-insensitive).
        var argAny: [String: [String]]?
        var argAll: [String: [String]]?
        var argAbsent: [String]?
        /// Argument names the app must be able to convert: date ("when"), range ("range"), duration.
        var resolves: [String]?
        var rangeResolves: String?
        var durationResolves: String?
        var asks: Bool?
        var mustContainAny: [String]?
        var mustContainAll: [String]?
        var mustNotContain: [String]?
        var mustNotContainSet: String?
    }

    var id: String
    var category: String
    var turns: [Turn]
    var expect: [Expectation]
    /// Saved memories the app's retrieval would attach to the last user message.
    var memories: [String]?

    var messages: [PromptMessage] {
        var out: [PromptMessage] = turns.map { turn in
            switch turn.role {
            case "assistant":
                let calls = (turn.calls ?? []).map { c in
                    ToolCall(name: c.name, arguments: c.args.compactMap { $0.count == 2 ? .init(name: $0[0], value: $0[1]) : nil })
                }
                return .assistant(turn.content ?? "", toolCalls: calls)
            case "tool":
                return .tool(turn.content ?? "")
            default:
                return .user(turn.content ?? "")
            }
        }
        if let memories, !memories.isEmpty, let i = out.lastIndex(where: { $0.role == .user }) {
            let saved = Date(timeIntervalSince1970: 1_792_454_400) // Oct 20, 2026
            out[i].content = MemoryContext.augment(out[i].content, with: memories.enumerated().map {
                Memory(id: "m\($0.offset)", text: $0.element, createdAt: saved, source: "user")
            })
        }
        return out
    }
}

enum EvalSuite {
    struct CaseResult: Codable {
        var id: String
        var category: String
        var passed: Bool
        var toolSelectionCorrect: Bool
        var expectedTools: [String]
        var actualTool: String
        var failureReasons: [String]
        var content: String
        var toolCalls: [ToolCall]
        var resolvedWhen: [String]
        var rawOutput: String
        var ttftMs: Double
        var generationTokensPerSec: Double
        var toolsOffered = true
    }

    struct Rate: Codable {
        var passed: Int
        var total: Int
        var rate: Double
        var wilson95Low: Double
        var wilson95High: Double

        init(_ passed: Int, _ total: Int) {
            self.passed = passed
            self.total = total
            rate = total > 0 ? Double(passed) / Double(total) : 0
            (wilson95Low, wilson95High) = Rate.wilson(passed, total)
        }

        static func wilson(_ k: Int, _ n: Int, z: Double = 1.96) -> (Double, Double) {
            guard n > 0 else { return (0, 0) }
            let p = Double(k) / Double(n), nn = Double(n)
            let denom = 1 + z * z / nn
            let center = (p + z * z / (2 * nn)) / denom
            let half = z * sqrt(p * (1 - p) / nn + z * z / (4 * nn * nn)) / denom
            return (max(0, center - half), min(1, center + half))
        }
    }

    struct Report: Codable {
        var device: String
        var os: String
        var model: String
        var seed: UInt32
        var toolRouting: String
        var systemPrompt: String
        var overall: Rate
        var toolSelection: Rate
        /// Tool called when the correct answer was no tool (lower is better).
        var falseToolCalls: Rate
        /// No tool called when one was expected (lower is better).
        var missedToolCalls: Rate
        var byCategory: [String: Rate]
        var meanTTFTms: Double
        var meanGenerationTokensPerSec: Double
        var thermalAtEnd: String
        var durationSeconds: Double
        var cases: [CaseResult]
    }

    static let offerPhrases = ["set a reminder", "want me to remind", "shall i remind", "i can remind", "create a reminder",
                               "add a reminder", "would you like me to set", "would you like a reminder", "want a reminder",
                               "would you like me to remind", "want me to set", "want me to add", "would you like me to add",
                               "add it to your calendar", "add this to your calendar", "want me to remember",
                               "should i remember", "save that to memory", "save this to memory"]
    static let successPhrases = ["i've set", "i have set", "reminder is set", "reminder has been set", "reminder has been created",
                                 "i've created", "i have created", "created a reminder", "all set", "i've added", "i have added",
                                 "i've scheduled", "i have scheduled", "i've sent", "i have sent", "i've saved", "i have saved",
                                 "i'll remember", "i will remember", "i've remembered", "i've marked", "i have marked",
                                 "i've deleted", "i have deleted", "i've removed", "i have removed", "has been deleted",
                                 "has been added", "has been saved", "marked as done", "marked as complete"]

    static func loadCases() throws -> [EvalCase] {
        guard let url = Bundle.main.url(forResource: "EvalCases", withExtension: "json") else {
            throw NSError(domain: "Eval", code: 1, userInfo: [NSLocalizedDescriptionKey: "EvalCases.json missing from app bundle"])
        }
        return try JSONDecoder().decode([EvalCase].self, from: Data(contentsOf: url))
    }

    @MainActor
    static func run(engine: LlamaEngine, registry: ToolRegistry, modelName: String,
                    status: (String) -> Void) async throws -> Report {
        let cases = try loadCases().filter { c in
            // `-LocaLMEvalFilter cal_,mem_` runs only cases whose id starts with one of the prefixes.
            guard let filter = UserDefaults.standard.string(forKey: "LocaLMEvalFilter"), !filter.isEmpty else { return true }
            return filter.split(separator: ",").contains { c.id.hasPrefix($0.trimmingCharacters(in: .whitespaces)) }
        }
        let start = Date()
        let systemPrompt = AssistantStore.systemPrompt()
        // Launch with `-LocaLMEvalAllTools YES` to measure the baseline without code-side tool routing.
        let allTools = UserDefaults.standard.bool(forKey: "LocaLMEvalAllTools")
        var results: [CaseResult] = []

        for (index, c) in cases.enumerated() {
            let messages = c.messages
            // Same tool routing as the app: groups come from the user's words for the current turn
            // (cases that end in a tool result continue that turn, so they get the same groups).
            let offered = allTools ? registry
                : ToolRouter.forFollowUpRound(ToolRouter.tools(for: messages, registry: registry), history: messages)
            let prompt = LFM3ChatTemplate.render(system: systemPrompt, tools: offered.specs,
                                                 messages: messages, enableThinking: false)
            var raw = ""
            var stats = GenerationStats()
            for try await event in engine.generate(prompt: prompt, maxTokens: 256) {
                if case .done(let full, let s) = event { raw = full; stats = s }
            }
            let parsed = ToolCallParser.parse(raw, thinkingOpen: false)
            var result = score(c, parsed: parsed, raw: raw, stats: stats)
            result.toolsOffered = !offered.tools.isEmpty
            results.append(result)
            status("[\(index + 1)/\(cases.count)] \(result.passed ? "PASS" : "FAIL") \(c.id)"
                   + (result.passed ? "" : " — " + result.failureReasons.joined(separator: "; ")))
        }

        let noToolCases = results.filter { $0.expectedTools == ["none"] }
        let toolCases = results.filter { !$0.expectedTools.contains("none") }
        var byCategory: [String: Rate] = [:]
        for category in Set(results.map(\.category)) {
            let r = results.filter { $0.category == category }
            byCategory[category] = Rate(r.filter(\.passed).count, r.count)
        }
        let n = Double(max(results.count, 1))
        return Report(
            device: DeviceMetrics.modelIdentifier, os: DeviceMetrics.osVersion, model: modelName,
            seed: engine.sampling.seed, toolRouting: allTools ? "all tools every turn" : "ToolRouter",
            systemPrompt: systemPrompt,
            overall: Rate(results.filter(\.passed).count, results.count),
            toolSelection: Rate(results.filter(\.toolSelectionCorrect).count, results.count),
            falseToolCalls: Rate(noToolCases.filter { $0.actualTool != "none" }.count, noToolCases.count),
            missedToolCalls: Rate(toolCases.filter { $0.actualTool == "none" }.count, toolCases.count),
            byCategory: byCategory,
            meanTTFTms: results.map(\.ttftMs).reduce(0, +) / n,
            meanGenerationTokensPerSec: results.map(\.generationTokensPerSec).reduce(0, +) / n,
            thermalAtEnd: DeviceMetrics.thermalState,
            durationSeconds: Date().timeIntervalSince(start),
            cases: results)
    }

    static func score(_ c: EvalCase, parsed: ParsedOutput, raw: String, stats: GenerationStats) -> CaseResult {
        let expectedTools = Array(Set(c.expect.map { $0.tool ?? "none" })).sorted()
        let actualTool = parsed.toolCalls.first?.name ?? "none"
        var firstReasons: [String]?
        var passed = false
        for e in c.expect {
            let reasons = check(e, parsed)
            if reasons.isEmpty { passed = true; break }
            if firstReasons == nil { firstReasons = reasons }
        }
        let resolved = parsed.toolCalls.compactMap { call -> String? in
            guard let when = call["when"], !when.isEmpty else { return nil }
            switch DateResolver.resolve(when) {
            case .success(let d): return "\(when) → \(d.display)"
            case .failure(let f): return "\(when) → FAILED (\(f))"
            }
        }
        return CaseResult(id: c.id, category: c.category, passed: passed,
                          toolSelectionCorrect: expectedTools.contains(actualTool),
                          expectedTools: expectedTools, actualTool: actualTool,
                          failureReasons: passed ? [] : (firstReasons ?? []),
                          content: parsed.content, toolCalls: parsed.toolCalls, resolvedWhen: resolved,
                          rawOutput: raw, ttftMs: stats.ttftMs,
                          generationTokensPerSec: stats.generationTokensPerSec)
    }

    /// Returns why the output does not meet the expectation (empty = it does).
    static func check(_ e: EvalCase.Expectation, _ p: ParsedOutput) -> [String] {
        var reasons: [String] = []
        let calls = p.toolCalls
        let text = p.content.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")

        if let tool = e.tool {
            let expectedCount = e.toolCount ?? 1
            if calls.isEmpty {
                reasons.append("expected \(tool), got no tool call")
            } else {
                if let wrong = calls.first(where: { $0.name != tool }) { reasons.append("called \(wrong.name), expected \(tool)") }
                if calls.count != expectedCount { reasons.append("\(calls.count) tool calls, expected \(expectedCount)") }
            }
            if let first = calls.first, first.name == tool, expectedCount == 1 {
                let title = (first["title"] ?? "").lowercased()
                let when = (first["when"] ?? "").lowercased()
                if let any = e.titleAny, !any.contains(where: { title.contains($0) }) {
                    reasons.append("title '\(title)' lacks any of \(any)")
                }
                if let all = e.whenAll, let missing = all.first(where: { !when.contains($0) }) {
                    reasons.append("when '\(when)' lacks '\(missing)'")
                }
                if e.whenAbsent == true, !when.isEmpty { reasons.append("expected no time, got '\(when)'") }
                for (arg, subs) in e.argAny ?? [:] {
                    let v = (first[arg] ?? "").lowercased()
                    if !subs.contains(where: { v.contains($0) }) { reasons.append("\(arg) '\(v)' lacks any of \(subs)") }
                }
                for (arg, subs) in e.argAll ?? [:] {
                    let v = (first[arg] ?? "").lowercased()
                    if let missing = subs.first(where: { !v.contains($0) }) { reasons.append("\(arg) '\(v)' lacks '\(missing)'") }
                }
                for arg in e.argAbsent ?? [] where !(first[arg] ?? "").isEmpty {
                    reasons.append("expected no \(arg), got '\(first[arg] ?? "")'")
                }
                if let arg = e.rangeResolves, DateRangeResolver.resolve(first[arg]) == nil {
                    reasons.append("app can't resolve range '\(first[arg] ?? "")'")
                }
                if let arg = e.durationResolves {
                    if let v = first[arg], !v.isEmpty {
                        if DurationParser.parse(v) == nil { reasons.append("app can't parse duration '\(v)'") }
                    } else {
                        reasons.append("missing '\(arg)'")
                    }
                }
            }
            let mustResolve = (e.whenResolves == true ? ["when"] : []) + (e.resolves ?? [])
            for arg in Set(mustResolve) {
                for call in calls where call.name == tool {
                    let value = call[arg] ?? ""
                    if value.isEmpty { reasons.append("missing '\(arg)'"); continue }
                    if case .failure(let f) = DateResolver.resolve(value) { reasons.append("app can't resolve '\(value)': \(f)") }
                }
            }
        } else if let first = calls.first {
            reasons.append("unexpected tool call \(first.name)")
        }

        if e.asks == true, !text.contains("?") { reasons.append("did not ask a question") }
        if let any = e.mustContainAny, !any.contains(where: { text.contains($0) }) {
            reasons.append("reply lacks any of \(any)")
        }
        if let all = e.mustContainAll, let missing = all.first(where: { !text.contains($0) }) {
            reasons.append("reply lacks '\(missing)'")
        }
        var forbidden = e.mustNotContain ?? []
        switch e.mustNotContainSet {
        case "offers": forbidden += offerPhrases
        case "success": forbidden += successPhrases
        default: break
        }
        if let hit = forbidden.first(where: { text.contains($0) }) {
            reasons.append("reply contains '\(hit)'")
        }
        return reasons
    }
}
