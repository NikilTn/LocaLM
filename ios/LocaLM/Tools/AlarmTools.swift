import AlarmKit
import Foundation
import SwiftUI
import UserNotifications

struct LocaLMAlarmData: AlarmMetadata {
    var label: String
}

/// Timers and alarms through AlarmKit (iOS 26): they ring through Silent mode and Focus, like the Clock app.
/// If AlarmKit isn't allowed, falls back to a local notification (which follows Silent mode).
final class AlarmService {
    static let shared = AlarmService()
    private let labelsKey = "LocaLMAlarmLabels" // alarm id -> label, for listing/cancelling by name

    struct Entry: Codable {
        var label: String
        var kind: String       // "timer" or "alarm"
        var fireDate: Date?
        var viaNotification: Bool
    }

    private var entries: [String: Entry] {
        get {
            (UserDefaults.standard.data(forKey: labelsKey)).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: labelsKey) }
    }

    private func alarmKitAuthorized() async -> Bool {
        switch AlarmManager.shared.authorizationState {
        case .authorized: return true
        case .notDetermined: return (try? await AlarmManager.shared.requestAuthorization()) == .authorized
        default: return false
        }
    }

    private func attributes(_ label: String) -> AlarmAttributes<LocaLMAlarmData> {
        AlarmAttributes(presentation: AlarmPresentation(alert: .init(title: LocalizedStringResource(stringLiteral: label))),
                        metadata: LocaLMAlarmData(label: label), tintColor: .blue)
    }

    func timer(seconds: TimeInterval, label: String) async -> ToolOutcome {
        let fire = Date().addingTimeInterval(seconds)
        let id = UUID()
        if await alarmKitAuthorized() {
            do {
                _ = try await AlarmManager.shared.schedule(id: id, configuration: .timer(duration: seconds, attributes: attributes(label)))
                entries[id.uuidString] = Entry(label: label, kind: "timer", fireDate: fire, viaNotification: false)
                return Self.created("timer", label, fire, viaNotification: false)
            } catch {
                // fall through to a notification
            }
        }
        return await notification(id: id, label: label, kind: "timer",
                                  trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, seconds), repeats: false), fire: fire)
    }

    /// `weekdays` empty = one-time at `date`; otherwise repeats at that clock time on those days.
    func alarm(at date: Date, weekdays: [Locale.Weekday], label: String) async -> ToolOutcome {
        let id = UUID()
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        if await alarmKitAuthorized() {
            let schedule: Alarm.Schedule = weekdays.isEmpty
                ? .fixed(date)
                : .relative(.init(time: .init(hour: comps.hour ?? 7, minute: comps.minute ?? 0), repeats: .weekly(weekdays)))
            do {
                _ = try await AlarmManager.shared.schedule(id: id, configuration: .alarm(schedule: schedule, attributes: attributes(label)))
                entries[id.uuidString] = Entry(label: label, kind: "alarm", fireDate: weekdays.isEmpty ? date : nil, viaNotification: false)
                return Self.created("alarm", label, date, viaNotification: false, repeats: weekdays)
            } catch {
                // fall through
            }
        }
        if !weekdays.isEmpty {
            return .failure("Repeating alarms need alarm permission. The user can allow it in Settings > LocaLM > Alarms & Timers.")
        }
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date), repeats: false)
        return await notification(id: id, label: label, kind: "alarm", trigger: trigger, fire: date)
    }

    private func notification(id: UUID, label: String, kind: String, trigger: UNNotificationTrigger, fire: Date) async -> ToolOutcome {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else {
            return .failure("Alarm and notification permissions are off. The user can enable them in Settings > LocaLM.")
        }
        let content = UNMutableNotificationContent()
        content.title = label
        content.body = kind == "timer" ? "Timer finished" : "Alarm"
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        do {
            try await center.add(UNNotificationRequest(identifier: id.uuidString, content: content, trigger: trigger))
        } catch {
            return .failure("Scheduling failed: \(error.localizedDescription)")
        }
        entries[id.uuidString] = Entry(label: label, kind: kind, fireDate: fire, viaNotification: true)
        return Self.created(kind, label, fire, viaNotification: true)
    }

    private static func created(_ kind: String, _ label: String, _ fire: Date, viaNotification: Bool,
                                repeats: [Locale.Weekday] = []) -> ToolOutcome {
        let t = DateFormatter()
        t.dateFormat = "h:mm a"
        let when = repeats.isEmpty ? DateResolver.display(fire) : "\(t.string(from: fire)) on \(repeats.map(\.rawValue).joined(separator: ", "))"
        let note = viaNotification ? " (as a notification; it follows Silent mode)" : ""
        return ToolOutcome(success: true, display: "\(kind.capitalized) “\(label)” · \(when)\(note)", payload: .object([
            ("status", .string("scheduled")), ("kind", .string(kind)), ("label", .string(label)),
            ("fires", .string(repeats.isEmpty ? DateResolver.iso(fire) : when)),
            ("delivery", .string(viaNotification ? "notification" : "alarm")),
        ]))
    }

    /// Active timers/alarms the app scheduled, soonest first.
    func active() async -> [(id: String, entry: Entry)] {
        var known = entries
        let alarmIDs = Set(((try? AlarmManager.shared.alarms) ?? []).map(\.id.uuidString))
        let pending = Set(await UNUserNotificationCenter.current().pendingNotificationRequests().map(\.identifier))
        known = known.filter { id, e in
            (e.viaNotification ? pending.contains(id) : alarmIDs.contains(id))
        }
        entries = known
        return known.map { ($0.key, $0.value) }.sorted { ($0.entry.fireDate ?? .distantFuture) < ($1.entry.fireDate ?? .distantFuture) }
    }

    func list() async -> ToolOutcome {
        let items = await active()
        let lines = items.map { "• \($0.entry.kind.capitalized): \($0.entry.label)" + ($0.entry.fireDate.map { " — \(DateResolver.display($0))" } ?? " — repeating") }
        return ToolOutcome(success: true, display: items.isEmpty ? "No timers or alarms." : lines.joined(separator: "\n"),
                           payload: .object([("status", .string("ok")), ("items", .array(items.map { item in
                               .object([("kind", .string(item.entry.kind)), ("label", .string(item.entry.label)),
                                        ("fires", item.entry.fireDate.map { .string(DateResolver.iso($0)) } ?? .string("repeating"))])
                           }))]))
    }

    func cancel(id: String) async -> ToolOutcome {
        guard let entry = entries[id] else { return .failure("That timer or alarm no longer exists.") }
        if entry.viaNotification {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
        } else if let uuid = UUID(uuidString: id) {
            do { try AlarmManager.shared.cancel(id: uuid) } catch { return .failure("Cancelling failed: \(error.localizedDescription)") }
        }
        entries[id] = nil
        return ToolOutcome(success: true, display: "Cancelled \(entry.kind) “\(entry.label)”",
                           payload: .object([("status", .string("cancelled")), ("kind", .string(entry.kind)), ("label", .string(entry.label))]))
    }
}

struct SetTimerTool: AssistantTool {
    let group = ToolGroup.alarms
    let spec = ToolSpec(
        name: "set_timer",
        description: "Start a countdown timer.",
        parameters: Schema.object([
            ("duration", Schema.string("Length as the user said it, e.g. '10 minutes' or '1 hour 30 minutes'")),
            ("label", Schema.string("What the timer is for, e.g. 'Pasta'. Optional.")),
        ], required: ["duration"]))

    func prepare(_ call: ToolCall) async throws -> PreparedAction {
        guard let raw = call["duration"], let seconds = DurationParser.parse(raw), seconds >= 1 else {
            throw ToolPreparationError.invalidArguments("Could not understand the duration '\(call["duration"] ?? "")'. Ask how long the timer should be.")
        }
        let label = (call["label"]?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "Timer"
        return PreparedAction(title: "Start timer", summary: "\(label) · \(DurationParser.display(seconds))", icon: "timer",
                              requiresConfirmation: false) {
            await AlarmService.shared.timer(seconds: seconds, label: label)
        }
    }
}

struct SetAlarmTool: AssistantTool {
    let group = ToolGroup.alarms
    let spec = ToolSpec(
        name: "set_alarm",
        description: "Set an alarm that rings at a time, optionally repeating.",
        parameters: Schema.object([
            ("when", Schema.string("Time (and day) as the user said it, e.g. '7am' or 'tomorrow at 6:30'")),
            ("repeats", Schema.string("Optional: 'daily', 'weekdays', 'weekends', or day names like 'Monday, Wednesday'")),
            ("label", Schema.string("Optional label, e.g. 'Gym'")),
        ], required: ["when"]))

    /// Days named in text, matched as whole words ("fri" never matches "friend").
    static func weekdays(_ text: String?) -> [Locale.Weekday] {
        let t = (text ?? "").lowercased()
        if t.isEmpty || t == "never" || t == "once" { return [] }
        if t.range(of: #"\b(daily|every ?day)\b"#, options: .regularExpression) != nil {
            return [.sunday, .monday, .tuesday, .wednesday, .thursday, .friday, .saturday]
        }
        if t.range(of: #"\bweekdays?\b"#, options: .regularExpression) != nil { return [.monday, .tuesday, .wednesday, .thursday, .friday] }
        if t.range(of: #"\bweekends?\b"#, options: .regularExpression) != nil { return [.saturday, .sunday] }
        let names: [(String, Locale.Weekday)] = [
            (#"\bsun(day)?s?\b"#, .sunday), (#"\bmon(day)?s?\b"#, .monday), (#"\btues?(day)?s?\b"#, .tuesday),
            (#"\bwed(nesday)?s?\b"#, .wednesday), (#"\bthu(rs?)?(day)?s?\b"#, .thursday), (#"\bfri(day)?s?\b"#, .friday),
            (#"\bsat(urday)?s?\b"#, .saturday),
        ]
        return names.filter { t.range(of: $0.0, options: .regularExpression) != nil }.map(\.1)
    }

    /// Repeat days the user stated themselves ("every Monday and Wednesday"), which win over the model's
    /// summary of them (it turned that into "weekdays" on device).
    static func userRepeatDays(_ text: String) -> [Locale.Weekday] {
        let t = text.lowercased()
        let repeating = t.range(of: #"\b(every|each|daily|weekdays?|weekends?|mondays|tuesdays|wednesdays|thursdays|fridays|saturdays|sundays)\b"#,
                                options: .regularExpression) != nil
        return repeating ? weekdays(t) : []
    }

    func prepare(_ call: ToolCall) async throws -> PreparedAction {
        guard let when = call["when"]?.trimmingCharacters(in: .whitespacesAndNewlines), !when.isEmpty else {
            throw ToolPreparationError.invalidArguments("Missing 'when'. Ask what time the alarm should ring.")
        }
        let resolved = try resolveWhen(when)
        guard resolved.hasTime else {
            throw ToolPreparationError.invalidArguments("'\(when)' has no time of day. Ask what time the alarm should ring.")
        }
        let modelDays = Self.weekdays(call["repeats"])
        let userDays = Self.userRepeatDays(ToolContext.userText)
        let days = userDays.isEmpty ? modelDays : userDays
        let label = (call["label"]?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "Alarm"
        let t = DateFormatter()
        t.dateFormat = "h:mm a"
        let summary = days.isEmpty ? "\(label) · \(resolved.display)"
                                   : "\(label) · \(t.string(from: resolved.date)), repeats \(days.map(\.rawValue).joined(separator: ", "))"
        return PreparedAction(title: "Set alarm", summary: summary, icon: "alarm", requiresConfirmation: true) {
            await AlarmService.shared.alarm(at: resolved.date, weekdays: days, label: label)
        }
    }
}

struct ListAlarmsTool: AssistantTool {
    let group = ToolGroup.alarms
    let spec = ToolSpec(name: "list_alarms", description: "List timers and alarms this app has set.",
                        parameters: Schema.object([], required: []))

    func prepare(_ call: ToolCall) async throws -> PreparedAction {
        PreparedAction(title: "Check timers & alarms", summary: "Active timers and alarms", icon: "alarm",
                       requiresConfirmation: false) { await AlarmService.shared.list() }
    }
}

struct CancelAlarmTool: AssistantTool {
    let group = ToolGroup.alarms
    let spec = ToolSpec(
        name: "cancel_alarm",
        description: "Cancel a timer or alarm this app has set.",
        parameters: Schema.object([
            ("label", Schema.string("Its label or kind, e.g. 'pasta timer', 'gym alarm', or 'timer'")),
        ], required: ["label"]))

    func prepare(_ call: ToolCall) async throws -> PreparedAction {
        let query = (call["label"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let items = await AlarmService.shared.active()
        guard !items.isEmpty else { throw ToolPreparationError.invalidArguments("There are no active timers or alarms. Tell the user.") }
        let chosen: (id: String, entry: AlarmService.Entry)
        if items.count == 1 {
            chosen = items[0]
        } else {
            switch FuzzyMatch.best(query, in: items, name: { "\($0.entry.label) \($0.entry.kind)" }) {
            case .match(let m): chosen = m
            case .none, .ambiguous:
                throw ToolPreparationError.invalidArguments("Several timers/alarms are active: "
                    + items.map { "'\($0.entry.label)' (\($0.entry.kind))" }.joined(separator: ", ") + ". Ask which one.")
            }
        }
        return PreparedAction(title: "Cancel \(chosen.entry.kind)", summary: chosen.entry.label
                                + (chosen.entry.fireDate.map { " · \(DateResolver.display($0))" } ?? ""),
                              icon: "alarm", requiresConfirmation: true, isDestructive: true) {
            await AlarmService.shared.cancel(id: chosen.id)
        }
    }
}
