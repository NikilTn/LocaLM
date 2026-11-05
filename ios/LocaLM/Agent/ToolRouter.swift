import Foundation

/// Decides in code which tools the model sees for a turn, before the model runs.
///
/// Small models call tools they were shown even when nobody asked (a haiku request became a reminder in
/// testing). Each tool group is shown only when the user's own words point at it. Quoted text (pasted
/// emails, notes, "translate this: '…'") and attached memories are ignored, so instructions inside
/// pasted content can't unlock tools.
enum ToolRouter {
    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static let patterns: [ToolGroup: NSRegularExpression] = [
        .reminders: regex(#"\b(remind\w*|forget|forgot|forgetting|to-?dos?|to do list|tasks?|need to do|have to do|ping me|nudge me|alert me|make sure i|note to self|remember to|check (it |that |this )?off|cross (it |that |this )?off)\b"#),
        .calendar: regex(#"\b(calendar|events?|meetings?|appointments?|schedul\w*|agenda|busy|free|availab\w*|block (off )?(some |an? |\d+ )?(time|hours?|minutes?|afternoon|morning)|plans? (for|on|this|tomorrow|today|tonight))\b"#),
        .memory: regex(#"\b(remember(?!\s+to\b)|memor(y|ies|ize)|keep in mind|don'?t forget that|for future reference|what did i (tell|say|mention)|i told you|do you know (my|about|what|who|when|where)|what do you know|(what|when|who|where|which)('?s| is| are| was) my|forget (that|about|what|my|i\b))"#),
        .alarms: regex(#"\b(timers?|alarms?|wake me( up)?|count ?down)\b"#),
        .contacts: regex(#"^\s*(please\s+)?(call|ring|dial|phone|text|message|email|e-mail|facetime)\b|\b(can|could|would|will) you (please )?(call|ring|dial|text|message|email|e-mail)\b|\bsend (a |an )?(text|message|sms|email|e-mail|imessage)\b|\b(phone number|number for|email address|contact info|contact details|my contacts|contacts?)\b|\bwhat'?s \w+'s (number|phone|email)\b|\btell (?!me\b)\w+ (that|i'?m|i'?ll|i will|i am)\b"#),
        .maps: regex(#"\b(directions?|navigate|navigation|route to|how (do i|can i|to) get to|take me to|drive to|walk to|apple maps|maps)\b"#),
        .shortcuts: regex(#"\bshortcuts?\b"#),
        .utilities: regex(#"\d\s*[-+*/×÷^x]\s*\d|\d\s*%|\b(calculate|compute|percent|percentage|square root|sqrt|tip on|split the bill|average of|sum of)\b|\bwhat'?s \d|\bhow much is \d|\b(convert|conversion)\b|\bin (celsius|fahrenheit|kelvin|km|kilometers|miles|kg|kilograms|pounds|lbs|grams|ounces|oz|liters|litres|gallons|cups|feet|meters|metres|inches|cm|mph|kph)\b|\bhow many \w+( \w+)? (are )?in (a |an |one )?\w+|\b\d+(\.\d+)?\s?(°\s?[cf]|km|kg|lbs?|ft|cm|mm|ml|oz|mph|kph)\b|\b(days? (until|till|left|before|since|to)|how (long|many days|many weeks) (until|till|since|before|to)|weeks? (until|till)|what day (of the week )?(is|was|will)|day of the week)\b|\b(what time is it in|time in|time zone|timezone|current time in|local time in)\b"#),
        .device: regex(#"\b(battery|charge level|charging|storage|disk space|free space|low power)\b"#),
        .web: regex(#"\b(search|look (it |this |that )?up|google|browse|online|on the (web|internet)|internet|current|currently|latest|recent|news|headlines|right now|as of|202[5-9]|who (is|are) (the )?(current |new )?(president|prime minister|ceo|leader|king|queen|pope|chancellor|governor|mayor|champion)|price of|stock|exchange rate|score|weather|forecast|open now|opening hours|closes)\b"#),
    ]

    /// “…”, "…", ‘…’, and '…' when the quote marks are not part of a word (so "don't" is untouched).
    /// Inside a '…' span, apostrophes followed by a letter ("user's") don't end the span.
    private static let quoted = try! NSRegularExpression(
        pattern: #"“[^”]*”|"[^"]*"|‘[^’]*’|(?<![A-Za-z])'(?:[^']|'(?=[A-Za-z]))+'(?![A-Za-z])"#)

    static func stripQuoted(_ text: String) -> String {
        quoted.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
    }

    static func groups(for text: String) -> Set<ToolGroup> {
        let unquoted = stripQuoted(MemoryContext.strip(text)).replacingOccurrences(of: "\u{2019}", with: "'")
        let range = NSRange(unquoted.startIndex..., in: unquoted)
        return Set(patterns.compactMap { group, re in re.firstMatch(in: unquoted, range: range) != nil ? group : nil })
    }

    static func wantsReminders(_ text: String) -> Bool { groups(for: text).contains(.reminders) }

    /// Tools to offer while answering the latest user message.
    static func tools(for history: [PromptMessage], registry: ToolRegistry) -> ToolRegistry {
        guard let lastUser = history.lastIndex(where: { $0.role == .user }) else { return ToolRegistry(tools: []) }
        var selected = groups(for: history[lastUser].content)

        // The user is answering the assistant's question ("Remind me about it" → "What and when?" →
        // "The dentist, tomorrow at 3pm"): keep the groups from that exchange.
        if let prevAssistant = history[..<lastUser].lastIndex(where: { $0.role == .assistant }),
           history[prevAssistant].content.contains("?") {
            selected.formUnion(groups(for: history[prevAssistant].content))
            if let prevUser = history[..<prevAssistant].last(where: { $0.role == .user }) {
                selected.formUnion(groups(for: prevUser.content))
            }
        }

        // A correction or follow-up to the previous action ("only on Monday and Wednesday", "make it 9
        // instead") names no tool, so offer the tools used in the previous turn again.
        if selected.isEmpty, !isAcknowledgement(history[lastUser].content),
           let prevUser = history[..<lastUser].lastIndex(where: { $0.role == .user }) {
            let usedNames = Set(history[prevUser..<lastUser].flatMap { $0.toolCalls.map(\.name) })
            selected.formUnion(registry.tools.filter { usedNames.contains($0.spec.name) }.map(\.group))
        }
        return registry.filtered(to: selected)
    }

    static func isAcknowledgement(_ text: String) -> Bool {
        let t = MemoryContext.strip(text).lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let acks: Set<String> = ["thanks", "thank you", "thx", "ok", "okay", "cool", "great", "nice", "perfect", "got it",
                                 "awesome", "sounds good", "no", "nope", "no thanks", "that's all", "thats all", "bye"]
        return acks.contains(t) || t.count <= 2
    }

    /// Tools that may run only once per user message. The model tends to search again after getting
    /// results (seen on device: it re-searched instead of answering), so after one search the follow-up
    /// round is generated without web_search and has to answer from the results.
    static let oncePerTurn: Set<String> = ["web_search"]

    static func forFollowUpRound(_ offered: ToolRegistry, history: [PromptMessage]) -> ToolRegistry {
        guard let lastUser = history.lastIndex(where: { $0.role == .user }) else { return offered }
        let used = Set(history[lastUser...].flatMap { $0.toolCalls.map(\.name) })
        let blocked = oncePerTurn.intersection(used)
        return blocked.isEmpty ? offered : ToolRegistry(tools: offered.tools.filter { !blocked.contains($0.spec.name) })
    }
}
