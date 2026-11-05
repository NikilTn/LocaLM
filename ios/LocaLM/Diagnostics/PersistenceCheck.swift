import Foundation

/// Two-launch check that chats survive an app restart, through the real AssistantStore.
/// Launch 1 (`-LocaLMPersistenceCheck YES`): sends one plain message and records the conversation ID.
/// Launch 2 (same flag): verifies the conversation was restored, then deletes only that conversation.
/// It refuses to run if the user already has a conversation, so real chats are never touched.
@MainActor
enum PersistenceCheck {
    static var isRequested: Bool { UserDefaults.standard.bool(forKey: "LocaLMPersistenceCheck") }

    private static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    private static var marker: URL { documents.appendingPathComponent("persistence-check-id.txt") }
    private static var output: URL { documents.appendingPathComponent("persistence-check.txt") }

    private static func write(_ text: String) {
        try? (text + "\n").write(to: output, atomically: true, encoding: .utf8)
    }

    static func run(models: ModelStore, assistant: AssistantStore) async {
        if let savedID = try? String(contentsOf: marker, encoding: .utf8) {
            // Launch 2
            guard assistant.currentConversationID == savedID else {
                write("FAIL phase 2: expected conversation \(savedID), restored \(assistant.currentConversationID ?? "none")")
                return
            }
            let users = assistant.items.filter { if case .user = $0.kind { return true } else { return false } }.count
            let replies = assistant.items.filter { if case .assistant = $0.kind { return true } else { return false } }.count
            let restoredMessages = assistant.historyCount
            let ok = users == 1 && replies == 1 && restoredMessages == 2
            assistant.clearChat()
            try? FileManager.default.removeItem(at: marker)
            for m in assistant.database?.allMemories() ?? [] where m.source == "persistence-check" {
                try? assistant.database?.deleteMemory(id: m.id)
            }
            let deleted = assistant.items.isEmpty && assistant.historyCount == 0 && assistant.currentConversationID == nil
            write("\(ok && deleted ? "PASS" : "FAIL") phase 2: restored \(users) user item(s), \(replies) reply item(s), \(restoredMessages) prompt messages; deleted afterwards: \(deleted)")
            return
        }

        // Launch 1
        guard assistant.currentConversationID == nil, assistant.items.isEmpty,
              !(assistant.database?.allMemories().contains { $0.text == "Sister's name is Maya." } ?? false) else {
            write("SKIPPED: a conversation or a matching memory already exists; not touching it.")
            return
        }
        let entry = ModelCatalog.recommended
        guard models.installed.contains(entry.id) else { write("SKIPPED: model not installed"); return }
        await assistant.load(entry, path: models.path(for: entry))
        // A saved memory the app should attach to the question automatically (retrieval in code).
        try? assistant.database?.addMemory("Sister's name is Maya.", source: "persistence-check")
        assistant.send("What's my sister's name?")
        while assistant.isBusy || assistant.items.count < 2 {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        guard let id = assistant.currentConversationID else { write("FAIL phase 1: no conversation saved"); return }
        try? id.write(to: marker, atomically: true, encoding: .utf8)
        let reply = assistant.items.last.map { item -> String in
            if case .assistant(let text, _) = item.kind { return text } else { return "\(item.kind)" }
        } ?? ""
        let attached = assistant.items.first?.memoriesUsed ?? []
        let recalled = reply.lowercased().contains("maya") && attached == ["Sister's name is Maya."]
        write("\(recalled ? "PASS" : "FAIL") phase 1: saved conversation with \(assistant.historyCount) prompt messages; memories attached: \(attached); reply: \(reply)")
    }
}
