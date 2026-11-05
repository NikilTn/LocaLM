import SwiftUI

/// Every saved memory, searchable, editable, and deletable. Stored only on this iPhone.
struct MemoryView: View {
    let database: ChatDatabase?
    @Environment(\.dismiss) private var dismiss
    @State private var memories: [Memory] = []
    @State private var search = ""
    @State private var editing: Memory?
    @State private var draft = ""
    @State private var adding = false
    @State private var confirmingDeleteAll = false

    var body: some View {
        NavigationStack {
            List {
                if database == nil {
                    Text("Memory storage is unavailable.").foregroundStyle(.secondary)
                } else if memories.isEmpty {
                    Text(search.isEmpty
                         ? "Nothing saved yet. Say “Remember that …” in chat, or tap + to add one."
                         : "No memories match.")
                        .foregroundStyle(.secondary)
                }
                ForEach(memories) { memory in
                    Button {
                        draft = memory.text
                        editing = memory
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(memory.text).foregroundStyle(.primary)
                            Text(memory.createdAt.formatted(date: .abbreviated, time: .shortened)
                                 + (memory.source == "manual" ? " · added by you" : " · saved from chat"))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    for i in offsets { try? database?.deleteMemory(id: memories[i].id) }
                    reload()
                }
            }
            .searchable(text: $search)
            .onChange(of: search) { _, _ in reload() }
            .navigationTitle("Memories")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { draft = ""; adding = true } label: { Image(systemName: "plus") }
                        .disabled(database == nil)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Delete all", role: .destructive) { confirmingDeleteAll = true }
                        .disabled(memories.isEmpty || !search.isEmpty)
                }
            }
            .confirmationDialog("Delete all saved memories from this iPhone?", isPresented: $confirmingDeleteAll,
                                titleVisibility: .visible) {
                Button("Delete all memories", role: .destructive) {
                    for m in database?.allMemories() ?? [] { try? database?.deleteMemory(id: m.id) }
                    reload()
                }
            }
            .alert("Edit memory", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
                TextField("Memory", text: $draft)
                Button("Save") {
                    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let m = editing, !text.isEmpty { try? database?.updateMemory(id: m.id, text: text) }
                    reload()
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("New memory", isPresented: $adding) {
                TextField("e.g. I'm allergic to peanuts", text: $draft)
                Button("Add") {
                    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { try? database?.addMemory(text, source: "manual") }
                    reload()
                }
                Button("Cancel", role: .cancel) {}
            }
            .onAppear(perform: reload)
        }
    }

    private func reload() {
        guard let database else { memories = []; return }
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        memories = q.isEmpty ? database.allMemories()
                             : database.allMemories().filter { $0.text.localizedCaseInsensitiveContains(q) }
    }
}
