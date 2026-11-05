import Foundation

/// "today", "tomorrow", "this week", "next week", "this weekend", "next 3 days", "Friday", "Dec 3"
/// → a concrete interval in the device's calendar and time zone.
enum DateRangeResolver {
    struct Range: Equatable {
        var interval: DateInterval
        var label: String
    }

    static func resolve(_ phrase: String?, now: Date = Date()) -> Range? {
        let cal = Calendar.current
        let text = (phrase ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let today = cal.startOfDay(for: now)
        func day(_ start: Date, _ label: String) -> Range {
            Range(interval: DateInterval(start: start, end: cal.date(byAdding: .day, value: 1, to: start)!), label: label)
        }

        switch text {
        case "", "today", "now", "rest of today", "this afternoon", "this evening":
            return day(today, "today")
        case "tonight":
            return Range(interval: DateInterval(start: now, end: cal.date(byAdding: .day, value: 1, to: today)!), label: "tonight")
        case "tomorrow":
            return day(cal.date(byAdding: .day, value: 1, to: today)!, "tomorrow")
        case "this week", "the rest of the week", "rest of the week", "week":
            let end = cal.dateInterval(of: .weekOfYear, for: now)?.end ?? cal.date(byAdding: .day, value: 7, to: today)!
            return Range(interval: DateInterval(start: today, end: end), label: "this week")
        case "next week":
            guard let thisWeek = cal.dateInterval(of: .weekOfYear, for: now),
                  let next = cal.dateInterval(of: .weekOfYear, for: thisWeek.end) else { return nil }
            return Range(interval: next, label: "next week")
        case "this weekend", "weekend", "the weekend":
            let weekend = cal.isDateInWeekend(now) ? cal.dateIntervalOfWeekend(containing: now)
                                                   : cal.nextWeekend(startingAfter: now)
            guard let w = weekend else { return nil }
            return Range(interval: DateInterval(start: max(w.start, today), end: w.end), label: "this weekend")
        case "this month", "month":
            let end = cal.dateInterval(of: .month, for: now)?.end ?? cal.date(byAdding: .day, value: 30, to: today)!
            return Range(interval: DateInterval(start: today, end: end), label: "this month")
        default:
            break
        }

        // "next 3 days", "next 10 days"
        if let m = try? NSRegularExpression(pattern: #"^(?:the )?next (\d{1,2}) days$"#)
            .firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let r = Swift.Range(m.range(at: 1), in: text), let n = Int(text[r]), n > 0 {
            return Range(interval: DateInterval(start: now, end: cal.date(byAdding: .day, value: n, to: today)!),
                         label: "the next \(n) days")
        }

        // A single day ("Friday", "Dec 3", "Friday afternoon").
        if case .success(let resolved) = DateResolver.resolve(text, now: now) {
            let start = cal.startOfDay(for: resolved.date)
            return day(start, DateResolver.displayDay(start))
        }
        return nil
    }
}

/// "30 minutes", "1 hour", "an hour", "1.5 hours", "90 min", "half an hour", "1h30m" → seconds.
enum DurationParser {
    static func parse(_ phrase: String?) -> TimeInterval? {
        let text = (phrase ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.isEmpty { return nil }
        if text.contains("half an hour") || text == "half hour" { return 1800 }
        if text == "an hour" || text == "one hour" || text == "hour" { return 3600 }

        let pattern = #"(\d+(?:\.\d+)?)\s*(hours?|hrs?|h|minutes?|mins?|m)(?![a-z])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        var total: TimeInterval = 0
        for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let nr = Range(m.range(at: 1), in: text), let ur = Range(m.range(at: 2), in: text),
                  let n = Double(text[nr]) else { continue }
            total += text[ur].hasPrefix("h") ? n * 3600 : n * 60
        }
        if total > 0 { return total <= 24 * 3600 ? total : nil }
        if let minutes = Double(text) { return minutes * 60 } // bare number: minutes
        return nil
    }

    static func display(_ seconds: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute]
        f.unitsStyle = .short
        return f.string(from: seconds) ?? "\(Int(seconds / 60)) min"
    }
}
