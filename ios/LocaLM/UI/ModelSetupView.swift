import SwiftUI

struct ModelSetupView: View {
    @EnvironmentObject private var models: ModelStore
    @EnvironmentObject private var assistant: AssistantStore
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Download a model once. After that, chat and reminders work with no internet connection.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if case .failed(let message) = assistant.phase {
                    Section { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
                Section("Models") {
                    ForEach(ModelCatalog.entries) { entry in
                        ModelRow(entry: entry, errorMessage: $errorMessage)
                    }
                }
                Section {
                    Text("Files are stored on this iPhone in Files › On My iPhone › LocaLM › Models.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("LocaLM")
            .refreshable { models.refresh() }
            .alert("Download failed", isPresented: Binding(get: { errorMessage != nil },
                                                          set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }
}

private struct ModelRow: View {
    @EnvironmentObject private var models: ModelStore
    @EnvironmentObject private var assistant: AssistantStore
    let entry: ModelEntry
    @Binding var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.displayName).font(.headline)
                    Text("\(entry.sizeText) · \(entry.note)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                actionButton
            }
            switch models.state(for: entry) {
            case .downloading(let received, let total):
                ProgressView(value: Double(received), total: Double(max(total, 1)))
                Text("\(ByteCountFormatter.string(fromByteCount: received, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)) · keep the app open")
                    .font(.caption2).foregroundStyle(.secondary)
            case .verifying:
                Text("Verifying checksum…").font(.caption2).foregroundStyle(.secondary)
            case .failed(let message):
                Text(message).font(.caption2).foregroundStyle(.red)
            case .idle:
                EmptyView()
            }
        }
        .padding(.vertical, 4)
        .swipeActions {
            if models.installed.contains(entry.id) {
                Button("Delete", role: .destructive) { models.delete(entry) }
            }
        }
    }

    @ViewBuilder private var actionButton: some View {
        if models.installed.contains(entry.id) {
            Button("Use") {
                Task { await assistant.load(entry, path: models.path(for: entry)) }
            }
            .buttonStyle(.borderedProminent)
        } else if case .downloading = models.state(for: entry) {
            Button("Cancel") { models.cancelDownload(entry) }
                .buttonStyle(.bordered)
        } else if case .verifying = models.state(for: entry) {
            ProgressView()
        } else {
            Button("Download") {
                Task {
                    do {
                        let url = try await models.download(entry)
                        await assistant.load(entry, path: url)
                    } catch {
                        if (error as NSError).code != NSURLErrorCancelled {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
            }
            .buttonStyle(.bordered)
        }
    }
}
