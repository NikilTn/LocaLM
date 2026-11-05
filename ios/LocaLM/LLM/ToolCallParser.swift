import Foundation

/// Splits raw LFM3 output into reasoning, visible text and tool calls.
///
/// LFM3 writes tool calls in this XML form (a superset of Qwen3-Coder's):
///
///     <tool_call>
///     <function=create_reminder>
///     <parameter=title>
///     Email professor
///     </parameter>
///     </function>
///     </tool_call>
struct ParsedOutput: Equatable {
    var thinking: String?
    var content: String
    var toolCalls: [ToolCall]
    /// True when a <tool_call> block was opened but could not be parsed into a call.
    var hasMalformedToolCall: Bool
}

enum ToolCallParser {
    private static let blockRegex = try! NSRegularExpression(
        pattern: "<tool_call>(.*?)(?:</tool_call>|\\z)", options: [.dotMatchesLineSeparators])
    private static let functionRegex = try! NSRegularExpression(
        pattern: "<function=([^>\\n]+)>", options: [])
    private static let parameterRegex = try! NSRegularExpression(
        pattern: "<parameter=([^>\\n]+)>\\n?(.*?)\\n?</parameter>", options: [.dotMatchesLineSeparators])

    /// - Parameter thinkingOpen: true when the prompt ended with an open `<think>` (reasoning enabled),
    ///   so the output starts inside the reasoning block.
    static func parse(_ raw: String, thinkingOpen: Bool) -> ParsedOutput {
        var thinking: String?
        var rest = raw

        if let close = rest.range(of: "</think>") {
            var t = String(rest[..<close.lowerBound])
            if let open = t.range(of: "<think>") { t = String(t[open.upperBound...]) }
            thinking = t.trimmingCharacters(in: .whitespacesAndNewlines)
            rest = String(rest[close.upperBound...])
        } else if thinkingOpen {
            // Reasoning never closed (ran out of tokens): everything is reasoning.
            return ParsedOutput(thinking: raw.trimmingCharacters(in: .whitespacesAndNewlines),
                                content: "", toolCalls: [], hasMalformedToolCall: false)
        }

        var calls: [ToolCall] = []
        var malformed = false
        let ns = rest as NSString
        let blocks = blockRegex.matches(in: rest, range: NSRange(location: 0, length: ns.length))
        for block in blocks {
            let body = ns.substring(with: block.range(at: 1))
            if let call = parseBlock(body) {
                calls.append(call)
            } else {
                malformed = true
            }
        }

        var visible = rest
        if let firstBlock = blocks.first {
            // Text after the first tool call is not shown; the model gets a fresh turn after the tool result.
            visible = ns.substring(to: firstBlock.range.location)
        }
        visible = visible.replacingOccurrences(of: "<|im_end|>", with: "")

        return ParsedOutput(thinking: thinking,
                            content: visible.trimmingCharacters(in: .whitespacesAndNewlines),
                            toolCalls: calls,
                            hasMalformedToolCall: malformed)
    }

    private static func parseBlock(_ body: String) -> ToolCall? {
        let ns = body as NSString
        let full = NSRange(location: 0, length: ns.length)
        if let fn = functionRegex.firstMatch(in: body, range: full) {
            let name = ns.substring(with: fn.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let args = parameterRegex.matches(in: body, range: full).map { m in
                ToolCall.Argument(
                    name: ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces),
                    value: ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return name.isEmpty ? nil : ToolCall(name: name, arguments: args)
        }
        // Fallback: JSON body {"name": ..., "arguments": {...}} used by some other models.
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = obj["name"] as? String else { return nil }
        let argsObj = obj["arguments"] as? [String: Any] ?? [:]
        let args = argsObj.keys.sorted().map { key -> ToolCall.Argument in
            let v = argsObj[key]
            let s = (v as? String) ?? (v.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed]) }
                .map { String(decoding: $0, as: UTF8.self) } ?? "")
            return .init(name: key, value: s)
        }
        return ToolCall(name: name, arguments: args)
    }

    /// Text that is safe to show while tokens are still streaming in.
    static func streamingPreview(_ raw: String, thinkingOpen: Bool) -> (visible: String, isThinking: Bool, isCallingTool: Bool) {
        var rest = raw
        if let close = rest.range(of: "</think>") {
            rest = String(rest[close.upperBound...])
        } else if thinkingOpen || rest.hasPrefix("<think>") {
            return ("", true, false)
        }
        if let call = rest.range(of: "<tool_call>") {
            return (String(rest[..<call.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines), false, true)
        }
        // Hide a partially typed tag at the end, e.g. "<tool_".
        if let lt = rest.lastIndex(of: "<"), !rest[lt...].contains(">") {
            rest = String(rest[..<lt])
        }
        return (rest.trimmingCharacters(in: .whitespacesAndNewlines), false, false)
    }
}
