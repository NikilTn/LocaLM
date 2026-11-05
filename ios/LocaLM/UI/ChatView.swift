import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var assistant: AssistantStore
    @EnvironmentObject private var briefing: BriefingScheduler
    @State private var input = ""
    @State private var confirmingClear = false
    @State private var showingMemories = false
    @State private var showingWebSettings = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let storageError = assistant.storageError {
                    Label(storageError, systemImage: "externaldrive.badge.exclamationmark")
                        .font(.caption).foregroundStyle(.orange)
                        .padding(.horizontal).padding(.vertical, 6)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if assistant.items.isEmpty { EmptyChatHint() }
                            ForEach(assistant.items) { item in
                                ChatItemView(item: item).id(item.id)
                            }
                        }
                        .padding()
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: assistant.items) { _, items in
                        if let last = items.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                    .onAppear {
                        if let last = assistant.items.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                Divider()
                inputBar
            }
            .navigationTitle("LocaLM")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { menu }
            }
            .confirmationDialog("Delete this conversation from your iPhone?", isPresented: $confirmingClear,
                                titleVisibility: .visible) {
                Button("Delete conversation", role: .destructive) { assistant.clearChat() }
            } message: {
                Text("Reminders, events, and saved memories stay.")
            }
            .sheet(isPresented: $showingMemories) {
                MemoryView(database: assistant.database)
            }
            .sheet(isPresented: $showingWebSettings) {
                WebSearchSettingsView()
            }
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $input, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                .focused($inputFocused)
                .submitLabel(.send)
                .onSubmit(send)
            if assistant.isBusy {
                Button(action: assistant.stop) {
                    Image(systemName: "stop.circle.fill").font(.system(size: 30))
                }
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
                }
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var menu: some View {
        Menu {
            Button("Memories", systemImage: "brain") { showingMemories = true }
            Button("Web search", systemImage: "magnifyingglass") { showingWebSettings = true }
            Toggle("Morning briefing", isOn: $briefing.enabled)
            if briefing.enabled {
                Picker("Briefing time", selection: $briefing.hour) {
                    ForEach(5..<12) { h in Text("\(h):00 AM").tag(h) }
                }
                .pickerStyle(.menu)
            }
            Toggle("Reasoning (slower)", isOn: $assistant.thinkingEnabled)
            Button("Delete conversation", systemImage: "trash", role: .destructive) { confirmingClear = true }
                .disabled(assistant.isBusy || assistant.items.isEmpty)
            if case .ready(let model, let info) = assistant.phase {
                Section("\(model.displayName) · ctx \(info.contextSize) · loaded in \(Int(info.loadMs)) ms") {
                    Button("Switch model", systemImage: "cpu") { Task { await assistant.unload() } }
                        .disabled(assistant.isBusy)
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    private func send() {
        let text = input
        input = ""
        assistant.send(text)
    }
}

private struct EmptyChatHint: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Running on this iPhone. Try:").font(.subheadline).foregroundStyle(.secondary)
            ForEach(["Remind me to email my professor tomorrow at 8 AM",
                     "What's on my calendar this week?",
                     "Remember that my sister's name is Maya",
                     "Explain how a heat pump works in 3 sentences"], id: \.self) {
                Text("“\($0)”").font(.callout)
            }
        }
        .padding(.top, 40)
    }
}

private struct ChatItemView: View {
    @EnvironmentObject private var assistant: AssistantStore
    let item: ChatItem

    var body: some View {
        switch item.kind {
        case .user(let text):
            VStack(alignment: .trailing, spacing: 4) {
                HStack {
                    Spacer(minLength: 40)
                    Text(text)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 18))
                        .foregroundStyle(.white)
                }
                if let used = item.memoriesUsed, !used.isEmpty {
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(used, id: \.self) { Text("• \($0)") }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Label("Used \(used.count) saved memor\(used.count == 1 ? "y" : "ies")", systemImage: "brain")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 260)
                }
            }
        case .assistant(let text, let status):
            VStack(alignment: .leading, spacing: 4) {
                if !text.isEmpty {
                    Text(text).textSelection(.enabled)
                }
                if let status {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                } else if text.isEmpty {
                    ProgressView().controlSize(.small)
                }
                if let stats = item.stats {
                    Text(String(format: "%.1f s to first token · %.0f tok/s · %d prompt tokens (%d cached)",
                                stats.ttftMs / 1000, stats.generationTokensPerSec,
                                stats.promptTokens, stats.reusedTokens))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .tool(let card):
            ToolCardView(id: item.id, card: card)
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(.orange)
        }
    }
}

private struct ToolCardView: View {
    @EnvironmentObject private var assistant: AssistantStore
    let id: UUID
    let card: ToolCard

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(card.title, systemImage: card.icon ?? "checklist").font(.subheadline.weight(.semibold))
            Text(card.summary).font(.callout)
            switch card.state {
            case .awaitingConfirmation:
                HStack {
                    if card.destructive == true {
                        Button("Delete", role: .destructive) { assistant.respond(to: id, approve: true) }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("Confirm") { assistant.respond(to: id, approve: true) }
                            .buttonStyle(.borderedProminent)
                    }
                    Button("Cancel", role: .cancel) { assistant.respond(to: id, approve: false) }
                        .buttonStyle(.bordered)
                }
            case .running:
                ProgressView().controlSize(.small)
            case .succeeded(let detail):
                Label(detail, systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
                if let links = card.links, !links.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(links, id: \.self) { link in
                            if let url = URL(string: link.url) {
                                Link(destination: url) {
                                    Label(link.title, systemImage: "link").font(.caption).lineLimit(1)
                                }
                            }
                        }
                    }
                }
            case .failed(let detail):
                Label(detail, systemImage: "xmark.octagon.fill")
                    .font(.caption).foregroundStyle(.red)
            case .cancelled:
                Label("Cancelled. Nothing was changed.", systemImage: "minus.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let payload = card.modelPayload {
                DisclosureGroup("What the model received") {
                    ScrollView(.horizontal) {
                        Text(payload)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 260)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}
