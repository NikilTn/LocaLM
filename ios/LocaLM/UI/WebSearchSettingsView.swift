import SwiftUI

/// Web search is the one feature that sends something off the device (the search words), so it has
/// its own settings: ask/always/off, and an optional Brave Search API key for full web results.
struct WebSearchSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var mode = WebSearchSettings.mode
    @State private var hasKey = WebSearchSettings.braveKey != nil
    @State private var keyDraft = ""
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Web search", selection: $mode) {
                        ForEach(WebSearchSettings.Mode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } footer: {
                    Text("Only your search words are sent, to \(hasKey ? "Brave Search" : "Wikipedia"). Your chats, memories, and other data stay on this iPhone.")
                }

                Section {
                    if hasKey {
                        Label("Brave Search key saved in the Keychain", systemImage: "key.fill")
                        Button("Remove key", role: .destructive) {
                            WebSearchSettings.setBraveKey(nil)
                            hasKey = false
                        }
                    } else {
                        SecureField("Brave Search API key (optional)", text: $keyDraft)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Save key") {
                            if WebSearchSettings.setBraveKey(keyDraft) { hasKey = WebSearchSettings.braveKey != nil }
                            keyDraft = ""
                        }
                        .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("Search provider")
                } footer: {
                    Text("Without a key, LocaLM searches Wikipedia: good for people, places, and organizations, but not news, prices, or weather. A Brave Search API key (api-dashboard.search.brave.com) gives full web results.")
                }

                Section {
                    Button(testing ? "Testing…" : "Test search") {
                        testing = true
                        testResult = nil
                        Task {
                            do {
                                let (provider, results, _) = try await WebSearchService.shared.search("current president of India")
                                testResult = "\(provider): \(results.count) result(s). " + (results.first.map { "\($0.title): \($0.snippet.prefix(120))…" } ?? "")
                            } catch {
                                testResult = "Failed: \(error.localizedDescription)"
                            }
                            testing = false
                        }
                    }
                    .disabled(testing)
                    if let testResult { Text(testResult).font(.caption) }
                }
            }
            .navigationTitle("Web search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onChange(of: mode) { _, m in WebSearchSettings.mode = m }
        }
    }
}
