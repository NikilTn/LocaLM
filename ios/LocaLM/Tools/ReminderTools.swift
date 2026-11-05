import EventKit
import Foundation

/// Native Reminders access through EventKit. Everything stays on the device.
final class RemindersService {
    static let shared = RemindersService()
    private var store: EKEventStore { EventKitStore.shared }

    private static var accessDenied: ToolOutcome { .failure(EventKitStore.accessDeniedMessage(.reminder)) }

    func create(title: String, due: ResolvedDate?) async -> ToolOutcome {
        guard await EventKitStore.ensureAccess(to: .reminder) else { return Self.accessDenied }
        guard let list = store.defaultCalendarForNewReminders() else {
            return .failure("No default Reminders list is set on this iPhone.")
        }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = list
        if let due {
            // Date-only reminders get only year/month/day, like an all-day reminder made in the Reminders app.
            let fields: Set<Calendar.Component> = due.hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
            var comps = Calendar.current.dateComponents(fields, from: due.date)
            comps.timeZone = .current
            reminder.dueDateComponents = comps
            if due.hasTime { reminder.addAlarm(EKAlarm(absoluteDate: due.date)) }
        }
        do {
            try store.save(reminder, commit: true)
        } catch {
            return .failure("Saving the reminder failed: \(error.localizedDescription)")
        }
        let dueText = due?.display ?? "no due date"
        return ToolOutcome(
            success: true,
            display: "Created “\(title)” · \(dueText) · list “\(list.title)”",
            payload: .object([
                ("status", .string("created")),
                ("title", .string(title)),
                ("due", due.map { .string($0.iso) } ?? .null),
                ("list", .string(list.title)),
            ]))
    }

    struct Item {
        var reminder: EKReminder
        var title: String
        var due: ResolvedDate?
    }

    /// nil when access is denied.
    func incomplete() async -> [Item]? {
        guard await EventKitStore.ensureAccess(to: .reminder) else { return nil }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let items: [Item] = await withCheckedContinuation { cont in
            store.fetchReminders(matching: predicate) { reminders in
                let mapped = (reminders ?? []).map { r -> Item in
                    let due = r.dueDateComponents.flatMap { comps in
                        Calendar.current.date(from: comps).map { ResolvedDate(date: $0, hasTime: comps.hour != nil) }
                    }
                    return Item(reminder: r, title: r.title ?? "(untitled)", due: due)
                }
                cont.resume(returning: mapped)
            }
        }
        return items.sorted { a, b in
            switch (a.due, b.due) {
            case let (x?, y?): return x.date < y.date
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.title < b.title
            }
        }
    }

    func listIncomplete(limit: Int = 10) async -> ToolOutcome {
        guard let items = await incomplete() else { return Self.accessDenied }
        let shown = Array(items.prefix(limit))
        let lines = shown.map { "• \($0.title)" + ($0.due.map { " — \($0.display)" } ?? "") }
        let display = shown.isEmpty
            ? "No incomplete reminders."
            : "\(items.count) incomplete reminder(s)" + (items.count > limit ? ", showing \(limit)" : "") + "\n" + lines.joined(separator: "\n")
        return ToolOutcome(
            success: true,
            display: display,
            payload: .object([
                ("status", .string("ok")),
                ("total", .number(Double(items.count))),
                ("reminders", .array(shown.map { item in
                    .object([("title", .string(item.title)),
                             ("due", item.due.map { .string($0.iso) } ?? .null)])
                })),
            ]))
    }

    /// Finds the one incomplete reminder the user means, or explains (to the model) why it can't.
    func find(_ query: String) async throws -> Item {
        if FuzzyMatch.isBulk(query) {
            throw ToolPreparationError.invalidArguments(
                "Only one reminder can be changed at a time. Tell the user and ask which one.")
        }
        guard let items = await incomplete() else {
            throw ToolPreparationError.invalidArguments(EventKitStore.accessDeniedMessage(.reminder))
        }
        switch FuzzyMatch.best(query, in: items, name: \.title) {
        case .match(let item):
            return item
        case .none:
            let sample = items.prefix(8).map { "'\($0.title)'" }.joined(separator: ", ")
            throw ToolPreparationError.invalidArguments(items.isEmpty
                ? "There are no incomplete reminders. Tell the user."
                : "No incomplete reminder matches '\(query)'. Existing reminders: \(sample). Ask the user which one they mean.")
        case .ambiguous(let matches):
            let names = matches.prefix(6).map { "'\($0.title)'" }.joined(separator: ", ")
            throw ToolPreparationError.invalidArguments(
                "\(matches.count) reminders match '\(query)': \(names). Ask the user which one they mean.")
        }
    }

    func complete(_ item: Item) async -> ToolOutcome {
        item.reminder.isCompleted = true
        do {
            try store.save(item.reminder, commit: true)
        } catch {
            return .failure("Marking the reminder done failed: \(error.localizedDescription)")
        }
        return ToolOutcome(success: true, display: "Marked “\(item.title)” as done",
                           payload: .object([("status", .string("completed")), ("title", .string(item.title))]))
    }

    func delete(_ item: Item) async -> ToolOutcome {
        do {
            try store.remove(item.reminder, commit: true)
        } catch {
            return .failure("Deleting the reminder failed: \(error.localizedDescription)")
        }
        return ToolOutcome(success: true, display: "Deleted “\(item.title)”",
                           payload: .object([("status", .string("deleted")), ("title", .string(item.title))]))
    }

    func update(_ item: Item, newTitle: String?, due: ResolvedDate?) async -> ToolOutcome {
        let r = item.reminder
        if let newTitle, !newTitle.isEmpty { r.title = newTitle }
        if let due {
            let fields: Set<Calendar.Component> = due.hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
            var comps = Calendar.current.dateComponents(fields, from: due.date)
            comps.timeZone = .current
            r.dueDateComponents = comps
            r.alarms?.forEach { r.removeAlarm($0) }
            if due.hasTime { r.addAlarm(EKAlarm(absoluteDate: due.date)) }
        }
        do {
            try store.save(r, commit: true)
        } catch {
            return .failure("Updating the reminder failed: \(error.localizedDescription)")
        }
        let title = r.title ?? item.title
        return ToolOutcome(success: true, display: "Updated “\(title)”" + (due.map { " · \($0.display)" } ?? ""),
                           payload: .object([("status", .string("updated")), ("title", .string(title)),
                                             ("due", due.map { .string($0.iso) } ?? (item.due.map { .string($0.iso) } ?? .null))]))
    }
}

struct UpdateReminderTool: AssistantTool {
    let group = ToolGroup.reminders
    let spec = ToolSpec(
        name: "update_reminder",
        description: "Change the time or text of one of the user's existing reminders.",
        parameters: Schema.object([
            ("title", Schema.string("Title or a few words of the existing reminder")),
            ("when", Schema.string("New date/time as the user said it, e.g. 'Friday at 9am'. Omit to keep the time.")),
            ("new_title", Schema.string("New text, only if the user wants to rename it")),
        ], required: ["title"]))

    func prepare(_ call: ToolCall) async throws -> PreparedAction {
        let query = (call["title"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw ToolPreparationError.invalidArguments("Missing 'title'. Ask which reminder to change.") }
        let newTitle = call["new_title"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        var due: ResolvedDate?
        if let when = call["when"]?.trimmingCharacters(in: .whitespacesAndNewlines), !when.isEmpty { due = try resolveWhen(when) }
        guard due != nil || !(newTitle ?? "").isEmpty else {
            throw ToolPreparationError.invalidArguments("Nothing to change. Ask the user for the new time or text.")
        }
        let item = try await RemindersService.shared.find(query)
        var summary = item.title
        if let t = newTitle, !t.isEmpty { summary += " → “\(t)”" }
        summary += " · " + (item.due?.display ?? "no time") + (due.map { " → \($0.display)" } ?? "")
        return PreparedAction(title: "Change reminder", summary: summary, icon: "checklist", requiresConfirmation: true) {
            await RemindersService.shared.update(item, newTitle: newTitle, due: due)
        }
    }
}

struct CreateReminderTool: AssistantTool {
    let group = ToolGroup.reminders
    let spec = ToolSpec(
        name: "create_reminder",
        description: "Create a reminder in the user's Reminders app.",
        parameters: Schema.object([
            ("title", Schema.string("Short reminder text, e.g. 'Email professor'")),
            ("when", Schema.string("Date and time exactly as the user said it, e.g. 'tomorrow at 8 AM'. Omit if the user gave no time.")),
        ], required: ["title"]))

    func prepare(_ call: ToolCall) async throws -> PreparedAction {
        let title = (call["title"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw ToolPreparationError.invalidArguments("Missing 'title'. Ask the user what the reminder should say.")
        }
        guard title.count <= 200 else {
            throw ToolPreparationError.invalidArguments("'title' is too long. Use a short title.")
        }
        if title.lowercased().hasPrefix("remind me") || title.lowercased() == "reminder" {
            throw ToolPreparationError.invalidArguments("The title just repeats the request. Ask the user what the reminder is about.")
        }

        var due: ResolvedDate?
        if let when = call["when"]?.trimmingCharacters(in: .whitespacesAndNewlines), !when.isEmpty {
            due = try resolveWhen(when)
        }

        let summary = "\(title) · " + (due?.display ?? "no due date")
        return PreparedAction(title: "Create reminder", summary: summary, icon: "checklist", requiresConfirmation: true) {
            await RemindersService.shared.create(title: title, due: due)
        }
    }
}

/// Shared by reminders and calendar: phrase → date, or an error message the model can relay.
func resolveWhen(_ when: String) throws -> ResolvedDate {
    switch DateResolver.resolve(when) {
    case .success(let d):
        return d
    case .failure(.unrecognized(let phrase)):
        throw ToolPreparationError.invalidArguments(
            "Could not understand the time '\(phrase)'. Ask the user for a specific date and time.")
    case .failure(.inPast(let d)):
        throw ToolPreparationError.invalidArguments(
            "'\(when)' resolves to \(DateResolver.display(d)), which is in the past. Ask the user for a future time.")
    }
}

struct ListRemindersTool: AssistantTool {
    let group = ToolGroup.reminders
    let spec = ToolSpec(
        name: "list_reminders",
        description: "List the user's incomplete reminders, soonest first.",
        parameters: Schema.object([], required: []))

    func prepare(_ call: ToolCall) async throws -> PreparedAction {
        // Read-only: no confirmation needed.
        PreparedAction(title: "Check reminders", summary: "Incomplete reminders", icon: "checklist",
                       requiresConfirmation: false) {
            await RemindersService.shared.listIncomplete()
        }
    }
}

struct CompleteReminderTool: AssistantTool {
    let group = ToolGroup.reminders
    let spec = ToolSpec(
        name: "complete_reminder",
        description: "Mark one of the user's existing reminders as done.",
        parameters: Schema.object([
            ("title", Schema.string("Title or a few words of the reminder, e.g. 'buy milk'")),
        ], required: ["title"]))

    func prepare(_ call: ToolCall) async throws -> PreparedAction {
        let query = (call["title"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            throw ToolPreparationError.invalidArguments("Missing 'title'. Ask the user which reminder is done.")
        }
        let item = try await RemindersService.shared.find(query)
        let summary = item.title + (item.due.map { " · \($0.display)" } ?? "")
        return PreparedAction(title: "Mark reminder done", summary: summary, icon: "checkmark.circle",
                              requiresConfirmation: true) {
            await RemindersService.shared.complete(item)
        }
    }
}

struct DeleteReminderTool: AssistantTool {
    let group = ToolGroup.reminders
    let spec = ToolSpec(
        name: "delete_reminder",
        description: "Delete one of the user's existing reminders.",
        parameters: Schema.object([
            ("title", Schema.string("Title or a few words of the reminder to delete")),
        ], required: ["title"]))

    func prepare(_ call: ToolCall) async throws -> PreparedAction {
        let query = (call["title"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            throw ToolPreparationError.invalidArguments("Missing 'title'. Ask the user which reminder to delete.")
        }
        let item = try await RemindersService.shared.find(query)
        let summary = item.title + (item.due.map { " · \($0.display)" } ?? "")
        return PreparedAction(title: "Delete reminder", summary: summary, icon: "trash",
                              requiresConfirmation: true, isDestructive: true) {
            await RemindersService.shared.delete(item)
        }
    }
}
