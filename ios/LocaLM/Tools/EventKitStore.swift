import EventKit
import Foundation

/// One EKEventStore for the whole app (Apple recommends a single long-lived instance).
enum EventKitStore {
    static let shared = EKEventStore()

    static func ensureAccess(to type: EKEntityType) async -> Bool {
        switch EKEventStore.authorizationStatus(for: type) {
        case .fullAccess:
            return true
        case .notDetermined:
            switch type {
            case .reminder: return (try? await shared.requestFullAccessToReminders()) ?? false
            case .event: return (try? await shared.requestFullAccessToEvents()) ?? false
            @unknown default: return false
            }
        default:
            return false
        }
    }

    static func accessDeniedMessage(_ type: EKEntityType) -> String {
        type == .reminder
            ? "Reminders access is off. The user can enable it in Settings > Privacy & Security > Reminders > LocaLM."
            : "Calendar access is off. The user can enable it in Settings > Privacy & Security > Calendars > LocaLM (Full Access)."
    }
}

/// Picks the item a user means by a loose name ("the dentist one", "buy milk").
enum FuzzyMatch {
    private static let filler: Set<String> = ["the", "my", "a", "an", "to", "reminder", "reminders", "one", "about",
                                              "for", "that", "this", "memory", "event", "item", "task"]

    static func words(_ s: String) -> [String] {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !filler.contains($0) }
    }

    /// 3 = same words, 2 = all words of one appear in the other, 1…2 = word overlap, 0 = unrelated.
    /// Whole words only, so "all" never matches "Call mom".
    static func score(query: String, candidate: String) -> Double {
        let q = words(query), c = words(candidate)
        guard !q.isEmpty, !c.isEmpty else { return 0 }
        if q == c { return 3 }
        let qs = Set(q), cs = Set(c)
        if qs.isSubset(of: cs) || cs.isSubset(of: qs) { return 2 }
        let jaccard = Double(qs.intersection(cs).count) / Double(qs.union(cs).count)
        return jaccard >= 0.34 ? 1 + jaccard : 0
    }

    /// "all", "everything", "every one" — bulk requests are not supported by single-item tools.
    static func isBulk(_ query: String) -> Bool {
        let q = Set(words(query))
        return !q.isEmpty && q.isSubset(of: ["all", "every", "everything", "each", "them", "these", "those", "of"])
    }

    enum Result<T> {
        case match(T)
        case none
        case ambiguous([T])
    }

    static func best<T>(_ query: String, in items: [T], name: (T) -> String) -> Result<T> {
        let scored = items.map { ($0, score(query: query, candidate: name($0))) }.filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
        guard let top = scored.first else { return .none }
        let tied = scored.filter { abs($0.1 - top.1) < 0.001 }
        return tied.count == 1 ? .match(top.0) : .ambiguous(tied.map(\.0))
    }
}
