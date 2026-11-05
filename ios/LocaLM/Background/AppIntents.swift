import AppIntents
import Foundation

/// Requests that arrive from Siri / Shortcuts / Spotlight while the app is starting or open.
@MainActor
final class IntentInbox: ObservableObject {
    static let shared = IntentInbox()
    @Published var pendingPrompt: String?
}

/// "Ask LocaLM …" — opens the app and sends the request to the on-device model (the model needs the
/// foreground, because iOS doesn't allow GPU work from background apps on iPhone).
struct AskLocaLMIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask LocaLM"
    static let description = IntentDescription("Opens LocaLM and asks the on-device assistant.")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Request", requestValueDialog: "What should I ask LocaLM?")
    var request: String

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentInbox.shared.pendingPrompt = request
        return .result()
    }
}

/// "LocaLM briefing" — answers in the background (no app launch, no model): today's events and reminders.
struct TodayBriefingIntent: AppIntent {
    static let title: LocalizedStringResource = "Today's Briefing"
    static let description = IntentDescription("Today's calendar events and due reminders, from this iPhone.")
    static let supportedModes: IntentModes = .background

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let (title, body) = await BriefingScheduler.summary(for: Date())
        return .result(value: body, dialog: IntentDialog(stringLiteral: "\(title). \(body)"))
    }
}

/// "Remember in LocaLM …" — saves a memory in the background without opening the app.
struct SaveMemoryIntent: AppIntent {
    static let title: LocalizedStringResource = "Save a Memory"
    static let description = IntentDescription("Saves a fact to LocaLM's on-device memory.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "What to remember", requestValueDialog: "What should LocaLM remember?")
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .result(dialog: "Nothing to save.") }
        let db = try ChatDatabase(url: ChatDatabase.defaultURL())
        try db.addMemory(trimmed, source: "siri")
        return .result(dialog: IntentDialog(stringLiteral: "Saved to LocaLM: \(trimmed)"))
    }
}

struct LocaLMShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AskLocaLMIntent(),
                    phrases: ["Ask \(.applicationName)", "Ask \(.applicationName) something"],
                    shortTitle: "Ask LocaLM", systemImageName: "sparkles")
        AppShortcut(intent: TodayBriefingIntent(),
                    phrases: ["\(.applicationName) briefing", "What's my day in \(.applicationName)"],
                    shortTitle: "Today's Briefing", systemImageName: "sun.max")
        AppShortcut(intent: SaveMemoryIntent(),
                    phrases: ["Remember something in \(.applicationName)", "Save a memory in \(.applicationName)"],
                    shortTitle: "Save a Memory", systemImageName: "brain")
    }
}
