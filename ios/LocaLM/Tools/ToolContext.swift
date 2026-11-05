import Foundation

/// The user's own words for the current turn, available to tools so code can catch arguments the model
/// got wrong (it rewrote "PM of India" as "president of India"; it turned "Monday and Wednesday" into
/// "weekdays"). Set by AssistantStore before tools run.
enum ToolContext {
    nonisolated(unsafe) static var userMessage = ""

    /// The user's message without attached memories.
    static var userText: String { MemoryContext.strip(userMessage) }
}
