import Foundation

/// A fact the user explicitly asked the assistant to remember. Independent of the loaded model.
struct Memory: Identifiable, Equatable, Codable {
    var id: String
    var text: String
    var createdAt: Date
    var source: String // "user" (saved via chat) or "manual" (typed in the Memories screen)
}

enum MemorySearch {
    private static let stopwords: Set<String> = [
        "a", "an", "the", "is", "are", "was", "were", "be", "been", "am", "i", "me", "my", "mine", "you", "your",
        "we", "our", "it", "its", "this", "that", "these", "those", "what", "whats", "which", "who", "whom", "when",
        "where", "why", "how", "do", "does", "did", "done", "can", "could", "would", "should", "will", "shall", "may",
        "might", "must", "have", "has", "had", "to", "of", "in", "on", "at", "for", "from", "with", "about", "as", "by",
        "and", "or", "but", "if", "so", "not", "no", "yes", "please", "tell", "know", "remember", "said", "say",
        "told", "there", "here", "any", "some", "all", "just", "like", "get", "got", "also", "too", "very", "really",
        "hi", "hello", "hey", "thanks", "thank", "ok", "okay", "im", "ive", "dont", "us", "them", "they", "he", "she",
        "him", "her", "his", "hers", "their", "up", "out", "now", "then", "than", "again", "want", "need", "make",
        "set", "remind", "reminder", "reminders", "today", "tomorrow", "tonight", "something", "anything", "thing",
        "things", "much", "many", "more", "most", "go", "going", "let", "lets", "one", "ll", "re", "ve", "s", "t", "d", "m",
    ]

    /// `"sister" OR "birthday"` for FTS5, or nil when nothing searchable is left.
    static func ftsQuery(_ text: String) -> String? {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 && !stopwords.contains($0) }
        let unique = Array(NSOrderedSet(array: words)) as? [String] ?? words
        guard !unique.isEmpty else { return nil }
        return unique.prefix(12).map { "\"\($0)\"" }.joined(separator: " OR ")
    }
}

/// Attaches relevant saved memories to the user's message before the model sees it, so recall does not
/// depend on the model deciding to search. The UI shows the original text; the model sees the block.
enum MemoryContext {
    static let marker = "\n\n[Saved memories"

    static func augment(_ text: String, with memories: [Memory]) -> String {
        guard !memories.isEmpty else { return text }
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        let lines = memories.map { "- \($0.text) (saved \(f.string(from: $0.createdAt)))" }
        return text + marker + " — things the user asked you to remember earlier. Use them only if relevant:]\n"
            + lines.joined(separator: "\n")
    }

    /// The user's own words, without the attached block (used for tool routing).
    static func strip(_ content: String) -> String {
        guard let r = content.range(of: marker) else { return content }
        return String(content[..<r.lowerBound])
    }
}
