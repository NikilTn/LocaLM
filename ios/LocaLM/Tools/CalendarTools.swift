import EventKit
import Foundation

/// Native Calendar access through EventKit (reads all calendars on the device, writes to the default one).
final class CalendarService {
    static let shared = CalendarService()
    private var store: EKEventStore { EventKitStore.shared }

    /// nil when access is denied.
    func events(in interval: DateInterval) async -> [EKEvent]? {
        guard await EventKitStore.ensureAccess(to: .event) else { return nil }
        let predicate = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: nil)
        return store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
    }

    static func describe(_ e: EKEvent) -> String {
        let title = e.title ?? "(untitled)"
        if e.isAllDay { return "\(title) — \(DateResolver.displayDay(e.startDate)), all day" }
        return "\(title) — \(timeRange(e.startDate, e.endDate))"
    }

    static func timeRange(_ start: Date, _ end: Date) -> String {
        let t = DateFormatter()
        t.dateFormat = "h:mm a"
        return "\(DateResolver.display(start))–\(t.string(from: end))"
    }

    static func payload(_ e: EKEvent) -> JSONValue {
        var pairs: [(String, JSONValue)] = [
            ("title", .string(e.title ?? "(untitled)")),
            ("start", .string(e.isAllDay ? DateResolver.isoDay(e.startDate) : DateResolver.iso(e.startDate))),
            ("end", .string(e.isAllDay ? DateResolver.isoDay(e.endDate) : DateResolver.iso(e.endDate))),
            ("all_day", .bool(e.isAllDay)),
        ]
        if let location = e.location, !location.isEmpty { pairs.append(("location", .string(location))) }
        return .object(pairs)
    }

    func list(_ range: DateRangeResolver.Range, limit: Int = 15) async -> ToolOutcome {
        guard let events = await events(in: range.interval) else {
            return .failure(EventKitStore.accessDeniedMessage(.event))
        }
        let shown = Array(events.prefix(limit))
        let display = shown.isEmpty
            ? "No events \(range.label)."
            : "\(events.count) event(s) \(range.label)" + (events.count > limit ? ", showing \(limit)" : "") + "\n"
                + shown.map { "• " + Self.describe($0) }.joined(separator: "\n")
        return ToolOutcome(success: true, display: display, payload: .object([
            ("status", .string("ok")),
            ("range", .string(range.label)),
            ("total", .number(Double(events.count))),
            ("events", .array(shown.map(Self.payload))),
        ]))
    }

    func create(title: String, start: Date, end: Date, allDay: Bool, location: String?, conflicts: [EKEvent]) async -> ToolOutcome {
        guard await EventKitStore.ensureAccess(to: .event) else { return .failure(EventKitStore.accessDeniedMessage(.event)) }
        guard let calendar = store.defaultCalendarForNewEvents else {
            return .failure("No default calendar is set on this iPhone.")
        }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.isAllDay = allDay
        event.calendar = calendar
        if let location, !location.isEmpty { event.location = location }
        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            return .failure("Saving the event failed: \(error.localizedDescription)")
        }
        let when = allDay ? DateResolver.displayDay(start) + ", all day" : Self.timeRange(start, end)
        return ToolOutcome(
            success: true,
            display: "Added “\(title)” · \(when) · calendar “\(calendar.title)”"
                + (conflicts.isEmpty ? "" : "\nOverlaps: " + conflicts.map { $0.title ?? "(untitled)" }.joined(separator: ", ")),
            payload: .object([
                ("status", .string("created")),
                ("event", Self.payload(event)),
                ("calendar", .string(calendar.title)),
                ("overlapping_events", .array(conflicts.map(Self.payload))),
            ]))
    }
}

struct ListEventsTool: AssistantTool {
    let group = ToolGroup.calendar
    let spec = ToolSpec(
        name: "list_events",
        description: "List events on the user's calendar for a day or range.",
        parameters: Schema.object([
            ("range", Schema.string("The day or range as the user said it, e.g. 'today', 'tomorrow', 'Friday', 'this week', 'next week'. Default 'today'.")),
        ], required: []))

    func prepare(_ call: ToolCall) async throws -> PreparedAction {
        let phrase = call["range"] ?? call["day"] ?? call["when"]
        guard let range = DateRangeResolver.resolve(phrase) else {
            throw ToolPreparationError.invalidArguments(
                "Could not understand the range '\(phrase ?? "")'. Ask the user which day or week they mean.")
        }
        return PreparedAction(title: "Check calendar", summary: "Events \(range.label)", icon: "calendar",
                              requiresConfirmation: false) {
            await CalendarService.shared.list(range)
        }
    }
}

struct CreateEventTool: AssistantTool {
    let group = ToolGroup.calendar
    let spec = ToolSpec(
        name: "create_event",
        description: "Add an event to the user's calendar.",
        parameters: Schema.object([
            ("title", Schema.string("Event title, e.g. 'Lunch with Sam'")),
            ("when", Schema.string("Start date and time exactly as the user said it, e.g. 'Friday at 2pm'")),
            ("duration", Schema.string("Length as the user said it, e.g. '30 minutes' or '2 hours'. Omit if not given (default 1 hour).")),
            ("location", Schema.string("Place, if the user gave one")),
        ], required: ["title", "when"]))

    func prepare(_ call: ToolCall) async throws -> PreparedAction {
        let title = (call["title"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 200 else {
            throw ToolPreparationError.invalidArguments("Missing or too long 'title'. Ask the user what the event is.")
        }
        guard let when = call["when"]?.trimmingCharacters(in: .whitespacesAndNewlines), !when.isEmpty else {
            throw ToolPreparationError.invalidArguments("Missing 'when'. Ask the user for the date and time.")
        }
        let resolved = try resolveWhen(when)

        let allDay = !resolved.hasTime
        var duration: TimeInterval = 3600
        if let raw = call["duration"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty, !allDay {
            guard let d = DurationParser.parse(raw) else {
                throw ToolPreparationError.invalidArguments("Could not understand the duration '\(raw)'. Ask the user how long it is.")
            }
            duration = d
        }
        let start = resolved.date
        let end = allDay ? Calendar.current.date(byAdding: .day, value: 1, to: start)! : start.addingTimeInterval(duration)
        let location = call["location"]?.trimmingCharacters(in: .whitespacesAndNewlines)

        // Look up overlaps now so the confirmation card can show them.
        var conflicts: [EKEvent] = []
        if !allDay, let existing = await CalendarService.shared.events(in: DateInterval(start: start, end: end)) {
            conflicts = existing.filter { !$0.isAllDay && $0.startDate < end && $0.endDate > start }
        }

        var summary = title + " · " + (allDay ? DateResolver.displayDay(start) + ", all day" : CalendarService.timeRange(start, end))
        if let location, !location.isEmpty { summary += " · \(location)" }
        if !conflicts.isEmpty {
            summary += "\n⚠︎ Overlaps: " + conflicts.map(CalendarService.describe).joined(separator: "; ")
        }
        return PreparedAction(title: "Add calendar event", summary: summary, icon: "calendar.badge.plus",
                              requiresConfirmation: true) {
            await CalendarService.shared.create(title: title, start: start, end: end, allDay: allDay,
                                                location: location, conflicts: conflicts)
        }
    }
}

extension CalendarService {
    /// The one upcoming event (next 60 days, or within `range`) the user means.
    func find(_ query: String, in range: DateRangeResolver.Range?) async throws -> EKEvent {
        if FuzzyMatch.isBulk(query) {
            throw ToolPreparationError.invalidArguments("Only one event can be changed at a time. Ask the user which one.")
        }
        let now = Date()
        let interval = range?.interval ?? DateInterval(start: Calendar.current.startOfDay(for: now),
                                                       end: Calendar.current.date(byAdding: .day, value: 60, to: now)!)
        guard let events = await events(in: interval) else {
            throw ToolPreparationError.invalidArguments(EventKitStore.accessDeniedMessage(.event))
        }
        switch FuzzyMatch.best(query, in: events, name: { $0.title ?? "" }) {
        case .match(let e):
            return e
        case .none:
            throw ToolPreparationError.invalidArguments(events.isEmpty
                ? "There are no upcoming events in that period. Tell the user."
                : "No upcoming event matches '\(query)'. Upcoming: " + events.prefix(8).map { "'\($0.title ?? "")'" }.joined(separator: ", ")
                  + ". Ask which one.")
        case .ambiguous(let es):
            throw ToolPreparationError.invalidArguments("\(es.count) events match '\(query)': "
                + es.prefix(5).map(Self.describe).joined(separator: "; ") + ". Ask which one.")
        }
    }

    func delete(_ event: EKEvent) async -> ToolOutcome {
        let description = Self.describe(event)
        do {
            try store.remove(event, span: .thisEvent, commit: true)
        } catch {
            return .failure("Deleting the event failed: \(error.localizedDescription)")
        }
        return ToolOutcome(success: true, display: "Deleted \(description)",
                           payload: .object([("status", .string("deleted")), ("event", .string(description))]))
    }

    func move(_ event: EKEvent, to start: Date, duration: TimeInterval?) async -> ToolOutcome {
        let length = duration ?? event.endDate.timeIntervalSince(event.startDate)
        event.startDate = start
        event.endDate = start.addingTimeInterval(length)
        event.isAllDay = false
        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            return .failure("Moving the event failed: \(error.localizedDescription)")
        }
        return ToolOutcome(success: true, display: "Moved to \(Self.describe(event))",
                           payload: .object([("status", .string("updated")), ("event", Self.payload(event))]))
    }
}

struct DeleteEventTool: AssistantTool {
    let group = ToolGroup.calendar
    let spec = ToolSpec(
        name: "delete_event",
        description: "Delete one upcoming event from the user's calendar.",
        parameters: Schema.object([
            ("title", Schema.string("Event title or a few words of it")),
            ("range", Schema.string("Optional day or range to look in, e.g. 'Friday'")),
        ], required: ["title"]))

    func prepare(_ call: ToolCall) async throws -> PreparedAction {
        let query = (call["title"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw ToolPreparationError.invalidArguments("Missing 'title'. Ask which event to delete.") }
        let range = call["range"].flatMap { $0.isEmpty ? nil : DateRangeResolver.resolve($0) }
        let event = try await CalendarService.shared.find(query, in: range)
        return PreparedAction(title: "Delete event", summary: CalendarService.describe(event), icon: "calendar.badge.minus",
                              requiresConfirmation: true, isDestructive: true) {
            await CalendarService.shared.delete(event)
        }
    }
}

struct MoveEventTool: AssistantTool {
    let group = ToolGroup.calendar
    let spec = ToolSpec(
        name: "move_event",
        description: "Reschedule one upcoming event to a new time.",
        parameters: Schema.object([
            ("title", Schema.string("Event title or a few words of it")),
            ("when", Schema.string("New start as the user said it, e.g. 'Friday at 4pm'")),
            ("duration", Schema.string("New length, only if the user changes it")),
        ], required: ["title", "when"]))

    func prepare(_ call: ToolCall) async throws -> PreparedAction {
        let query = (call["title"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw ToolPreparationError.invalidArguments("Missing 'title'. Ask which event to move.") }
        guard let when = call["when"]?.trimmingCharacters(in: .whitespacesAndNewlines), !when.isEmpty else {
            throw ToolPreparationError.invalidArguments("Missing 'when'. Ask for the new time.")
        }
        let resolved = try resolveWhen(when)
        guard resolved.hasTime else { throw ToolPreparationError.invalidArguments("'\(when)' has no time of day. Ask for the new time.") }
        var duration: TimeInterval?
        if let raw = call["duration"], !raw.isEmpty {
            guard let d = DurationParser.parse(raw) else { throw ToolPreparationError.invalidArguments("Could not understand the duration '\(raw)'.") }
            duration = d
        }
        let event = try await CalendarService.shared.find(query, in: nil)
        let length = duration ?? event.endDate.timeIntervalSince(event.startDate)
        let summary = CalendarService.describe(event) + "\n→ " + CalendarService.timeRange(resolved.date, resolved.date.addingTimeInterval(length))
        return PreparedAction(title: "Move event", summary: summary, icon: "calendar", requiresConfirmation: true) {
            await CalendarService.shared.move(event, to: resolved.date, duration: duration)
        }
    }
}
