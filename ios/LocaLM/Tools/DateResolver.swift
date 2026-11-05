import Foundation

/// A date the app worked out from the user's words. `hasTime == false` means the user named a day
/// but no time ("Friday"), which becomes a date-only reminder instead of an invented clock time.
struct ResolvedDate: Equatable {
    var date: Date
    var hasTime: Bool

    var display: String {
        hasTime ? DateResolver.display(date) : DateResolver.displayDay(date) + " (no time)"
    }

    /// "2026-10-29T08:00:00-07:00" or "2026-10-30" for date-only.
    var iso: String {
        hasTime ? DateResolver.iso(date) : DateResolver.isoDay(date)
    }
}

/// Turns the phrase the model copied from the user ("tomorrow at 8 AM") into a concrete date, in code,
/// using the device's calendar and time zone. The model never does date arithmetic.
enum DateResolver {
    enum Failure: Error, Equatable {
        case unrecognized(String)
        case inPast(Date)
    }

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)

    private static let timeRegex = try! NSRegularExpression(
        pattern: #"(\d{1,2}(:\d{2})?\s*(am|pm|a\.m\.|p\.m\.))|(\d{1,2}:\d{2})|(\bat\s+\d{1,2}\b)|\b(noon|midnight|morning|afternoon|evening|tonight|night|o'?clock)\b"#,
        options: [.caseInsensitive])

    private static let relativeRegex = try! NSRegularExpression(
        pattern: #"^in\s+(\d+|a|an|one|two|three|four|five|ten|fifteen|twenty|thirty)\s+(minute|min|hour|hr|day|week)s?$"#,
        options: [.caseInsensitive])

    static func resolve(_ phrase: String, now: Date = Date()) -> Result<ResolvedDate, Failure> {
        let text = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let calendar = Calendar.current

        // ISO-8601, in case the model normalizes the date itself.
        let isoFull = ISO8601DateFormatter()
        isoFull.formatOptions = [.withInternetDateTime]
        if let d = isoFull.date(from: text) { return check(ResolvedDate(date: d, hasTime: true), now: now) }
        let isoLocal = ISO8601DateFormatter()
        isoLocal.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        isoLocal.timeZone = .current
        if let d = isoLocal.date(from: text) { return check(ResolvedDate(date: d, hasTime: true), now: now) }
        let isoDate = ISO8601DateFormatter()
        isoDate.formatOptions = [.withFullDate]
        isoDate.timeZone = .current
        if let d = isoDate.date(from: text) { return check(ResolvedDate(date: d, hasTime: false), now: now) }

        if let resolved = relativeDuration(text, now: now) { return .success(resolved) }

        guard let detector,
              let match = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              var date = match.date else {
            return .failure(.unrecognized(text))
        }

        guard mentionsTime(text) else {
            // NSDataDetector fills in 12:00 for "Friday"; drop it instead of inventing a time.
            return check(ResolvedDate(date: calendar.startOfDay(for: date), hasTime: false), now: now)
        }
        // A bare time ("8am") that already passed today means the next occurrence.
        if date < now, !mentionsDay(text),
           let next = calendar.date(byAdding: .day, value: 1, to: date), next > now {
            date = next
        }
        return check(ResolvedDate(date: date, hasTime: true), now: now)
    }

    private static func check(_ r: ResolvedDate, now: Date) -> Result<ResolvedDate, Failure> {
        if r.hasTime {
            return r.date < now.addingTimeInterval(-60) ? .failure(.inPast(r.date)) : .success(r)
        }
        return r.date < Calendar.current.startOfDay(for: now) ? .failure(.inPast(r.date)) : .success(r)
    }

    /// "in 20 minutes", "in an hour", "in 2 days"
    private static func relativeDuration(_ text: String, now: Date) -> ResolvedDate? {
        guard let m = relativeRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let numRange = Range(m.range(at: 1), in: text),
              let unitRange = Range(m.range(at: 2), in: text) else { return nil }
        let words = ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
                     "ten": 10, "fifteen": 15, "twenty": 20, "thirty": 30]
        let token = text[numRange].lowercased()
        guard let n = Int(token) ?? words[token], n > 0, n <= 10_000 else { return nil }
        let component: Calendar.Component
        switch text[unitRange].lowercased() {
        case "minute", "min": component = .minute
        case "hour", "hr": component = .hour
        case "day": component = .day
        default: component = .weekOfYear
        }
        guard let date = Calendar.current.date(byAdding: component, value: n, to: now) else { return nil }
        return ResolvedDate(date: date, hasTime: true)
    }

    static func mentionsTime(_ text: String) -> Bool {
        timeRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func mentionsDay(_ text: String) -> Bool {
        let t = text.lowercased()
        let dayWords = ["today", "tonight", "tomorrow", "monday", "tuesday", "wednesday", "thursday", "friday",
                        "saturday", "sunday", "week", "month", "jan", "feb", "mar", "apr", "may", "jun", "jul",
                        "aug", "sep", "oct", "nov", "dec", "/", "-"]
        return dayWords.contains { t.contains($0) }
    }

    static func display(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d 'at' h:mm a"
        return f.string(from: date)
    }

    static func displayDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d"
        return f.string(from: date)
    }

    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f.string(from: date)
    }

    static func isoDay(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        f.timeZone = .current
        return f.string(from: date)
    }
}
