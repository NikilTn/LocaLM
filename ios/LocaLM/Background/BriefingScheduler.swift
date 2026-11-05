import BackgroundTasks
import EventKit
import Foundation
import SQLite3
import UserNotifications

/// What runs when LocaLM is not on screen. iOS does not let a third-party iPhone app run the GPU (and so
/// the LLM) in the background, so background work here is deterministic code:
///   - Morning briefing: a local notification built from Calendar + Reminders, pre-scheduled for the next
///     3 days and refreshed by a BGAppRefreshTask (best effort) and every time the app opens.
///   - Maintenance: a BGProcessingTask that compacts the database, only while charging.
/// Alarms/timers (AlarmKit) and reminders (EventKit) fire on their own with the app closed.
@MainActor
final class BriefingScheduler: ObservableObject {
    static let shared = BriefingScheduler()

    static let refreshTaskID = "com.nikilthalapaneni.localm.briefing-refresh"
    static let maintenanceTaskID = "com.nikilthalapaneni.localm.maintenance"
    private static let notificationPrefix = "localm-briefing-"
    private static let daysAhead = 3

    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "LocaLMBriefingEnabled"); Task { await refresh() } }
    }
    @Published var hour: Int {
        didSet { UserDefaults.standard.set(hour, forKey: "LocaLMBriefingHour"); Task { await refresh() } }
    }
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var status = ""

    private init() {
        enabled = UserDefaults.standard.bool(forKey: "LocaLMBriefingEnabled")
        let saved = UserDefaults.standard.integer(forKey: "LocaLMBriefingHour")
        hour = saved == 0 ? 8 : saved
    }

    // MARK: Background task registration (must happen before launch finishes)

    nonisolated static func registerBackgroundTasks(databaseURL: URL?) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskID, using: nil) { task in
            let work = Task { @MainActor in
                await BriefingScheduler.shared.refresh()
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: maintenanceTaskID, using: nil) { task in
            if let databaseURL { Self.compact(databaseURL) }
            task.setTaskCompleted(success: true)
            Self.scheduleMaintenance()
        }
    }

    nonisolated static func scheduleMaintenance() {
        let request = BGProcessingTaskRequest(identifier: maintenanceTaskID)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = false
        request.earliestBeginDate = Date().addingTimeInterval(12 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Checkpoint the WAL and merge the full-text index segments.
    nonisolated static func compact(_ url: URL) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { sqlite3_close(db); return }
        sqlite3_exec(db, "INSERT INTO memories(memories) VALUES('optimize'); PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil)
        sqlite3_close(db)
    }

    private func scheduleRefreshTask() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshTaskID)
        guard enabled else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        // Ask to run a few hours before the next briefing; iOS decides the actual time.
        request.earliestBeginDate = max(Date().addingTimeInterval(15 * 60), nextBriefingDate().addingTimeInterval(-4 * 3600))
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            status = "Background refresh not available: \(error.localizedDescription)"
        }
    }

    private func nextBriefingDate(after now: Date = Date()) -> Date {
        let cal = Calendar.current
        let today = cal.date(bySettingHour: hour, minute: 0, second: 0, of: now)!
        return today > now ? today : cal.date(byAdding: .day, value: 1, to: today)!
    }

    // MARK: Building the notifications

    /// Recomputes and reschedules the next few briefings. Called on app open, from the refresh task,
    /// and when the setting changes.
    func refresh() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(Self.notificationPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        scheduleRefreshTask()
        guard enabled else { status = "Off"; return }

        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else {
            status = "Notifications are off for LocaLM in Settings."
            return
        }
        var first = nextBriefingDate()
        var scheduled = 0
        for _ in 0..<Self.daysAhead {
            let (title, body) = await Self.summary(for: first)
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: first)
            let id = Self.notificationPrefix + DateResolver.isoDay(first)
            if (try? await center.add(UNNotificationRequest(identifier: id, content: content,
                                                            trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))) != nil {
                scheduled += 1
            }
            first = Calendar.current.date(byAdding: .day, value: 1, to: first)!
        }
        lastRefresh = Date()
        status = "Scheduled \(scheduled) briefing(s), next \(DateResolver.display(nextBriefingDate()))"
    }

    /// Deterministic summary of a day's events and due reminders. No LLM involved.
    static func summary(for day: Date) async -> (String, String) {
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        let end = cal.date(byAdding: .day, value: 1, to: start)!
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d"
        let title = "Your day · \(f.string(from: start))"
        var lines: [String] = []

        if EKEventStore.authorizationStatus(for: .event) == .fullAccess,
           let events = await CalendarService.shared.events(in: DateInterval(start: start, end: end)) {
            if events.isEmpty {
                lines.append("No events.")
            } else {
                let t = DateFormatter()
                t.dateFormat = "h:mm a"
                let list = events.prefix(3).map { ($0.isAllDay ? "All day" : t.string(from: $0.startDate)) + " " + ($0.title ?? "") }
                lines.append("\(events.count) event\(events.count == 1 ? "" : "s"): " + list.joined(separator: "; ")
                             + (events.count > 3 ? "; …" : ""))
            }
        }
        if EKEventStore.authorizationStatus(for: .reminder) == .fullAccess,
           let reminders = await RemindersService.shared.incomplete() {
            let due = reminders.filter { r in r.due.map { $0.date < end } ?? false }
            if !due.isEmpty {
                let overdue = due.filter { $0.due!.date < start }.count
                lines.append("\(due.count) reminder\(due.count == 1 ? "" : "s") due" + (overdue > 0 ? " (\(overdue) overdue)" : "") + ": "
                             + due.prefix(3).map(\.title).joined(separator: "; ") + (due.count > 3 ? "; …" : ""))
            }
        }
        if lines.isEmpty { lines.append("Open LocaLM to allow Calendar and Reminders access for a fuller briefing.") }
        return (title, lines.joined(separator: "\n"))
    }
}
