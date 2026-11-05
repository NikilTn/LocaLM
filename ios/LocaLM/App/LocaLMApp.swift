import SwiftUI

@main
struct LocaLMApp: App {
    @StateObject private var models = ModelStore()
    @StateObject private var assistant = AssistantStore()
    @StateObject private var selfTest = SelfTest()

    init() {
        // Background task handlers must be registered before launch finishes.
        BriefingScheduler.registerBackgroundTasks(databaseURL: try? ChatDatabase.defaultURL())
        BriefingScheduler.scheduleMaintenance()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(models)
                .environmentObject(assistant)
                .environmentObject(selfTest)
                .environmentObject(BriefingScheduler.shared)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var models: ModelStore
    @EnvironmentObject private var assistant: AssistantStore
    @EnvironmentObject private var selfTest: SelfTest
    @ObservedObject private var inbox = IntentInbox.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch assistant.phase {
            case .ready:
                ChatView()
            case .loading(let message):
                VStack(spacing: 12) {
                    ProgressView()
                    Text(message).foregroundStyle(.secondary)
                }
            case .noModel, .failed:
                ModelSetupView()
            }
        }
        .overlay(alignment: .bottom) {
            if SelfTest.isRequested { SelfTestOverlay() }
        }
        .task {
            if SelfTest.isRequested {
                await selfTest.run(models: models, assistant: assistant)
            } else if PersistenceCheck.isRequested {
                await PersistenceCheck.run(models: models, assistant: assistant)
            } else if let entry = ModelCatalog.entries.first(where: { models.installed.contains($0.id) }) {
                // Auto-load the first installed model so the app opens straight into chat.
                await assistant.load(entry, path: models.path(for: entry))
                deliverPendingPrompt()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                assistant.appDidEnterBackground()
            case .active:
                Task { await BriefingScheduler.shared.refresh() }
            default:
                break
            }
        }
        .onChange(of: inbox.pendingPrompt) { _, _ in deliverPendingPrompt() }
        .onChange(of: assistant.phase) { _, _ in deliverPendingPrompt() }
    }

    /// A request from Siri/Shortcuts ("Ask LocaLM …") is sent once the model is ready.
    private func deliverPendingPrompt() {
        guard let prompt = inbox.pendingPrompt, case .ready = assistant.phase, !assistant.isBusy else { return }
        inbox.pendingPrompt = nil
        assistant.send(prompt)
    }
}

private struct SelfTestOverlay: View {
    @EnvironmentObject private var selfTest: SelfTest

    var body: some View {
        ScrollView {
            Text(selfTest.log.joined(separator: "\n"))
                .font(.system(.caption2, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(maxHeight: 220)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding()
    }
}
