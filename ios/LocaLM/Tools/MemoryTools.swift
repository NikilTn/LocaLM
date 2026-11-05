import Foundation

/// Memory tools. Saving and deleting need a tap on Confirm, so the user always sees the exact text stored.
struct SaveMemoryTool: AssistantTool {
    let group = ToolGroup.memory
    let database: ChatDatabase?
    let spec = ToolSpec(
        name: "save_memory",
        description: "Save a fact for future conversations. Call it whenever the user says remember, keep in mind, note that, or for future reference.",
        parameters: Schema.object([
            ("text", Schema.string("The fact as one short standalone sentence, e.g. 'Sister's name is Maya.'")),
        ], required: ["text"]))

    func prepare(_ call: ToolCall) async throws -> PreparedAction {
        guard let database else { throw ToolPreparationError.invalidArguments("Memory storage is unavailable on this device.") }
        let text = (call["text"] ?? call["fact"] ?? call["memory"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ToolPreparationError.invalidArguments("Missing 'text'. Ask the user what to remember.") }
        guard text.count <= 500 else { throw ToolPreparationError.invalidArguments("'text' is too long. Save one short fact.") }

        let normalized = FuzzyMatch.words(text)
        if let existing = database.allMemories().first(where: { FuzzyMatch.words($0.text) == normalized }) {
            return PreparedAction(title: "Memory", summary: existing.text, icon: "brain", requiresConfirmation: false) {
                ToolOutcome(success: true, display: "Already saved: “\(existing.text)”",
                            payload: .object([("status", .string("already_saved")), ("text", .string(existing.text))]))
            }
        }
        return PreparedAction(title: "Save to memory", summary: text, icon: "brain", requiresConfirmation: true) {
            do {
                let memory = try database.addMemory(text, source: "user")
                return ToolOutcome(success: true, display: "Saved “\(memory.text)”",
                                   payload: .object([("status", .string("saved")), ("text", .string(memory.text))]))
            } catch {
                return .failure("Saving the memory failed: \(error.localizedDescription)")
            }
        }
    }
}

struct SearchMemoryTool: AssistantTool {
    let group = ToolGroup.memory
    let database: ChatDatabase?
    let spec = ToolSpec(
        name: "search_memory",
        description: "Search facts the user asked you to remember. Leave query empty to list recent ones.",
        parameters: Schema.object([
            ("query", Schema.string("A few keywords, e.g. 'sister birthday'")),
        ], required: []))

    func prepare(_ call: ToolCall) async throws -> PreparedAction {
        guard let database else { throw ToolPreparationError.invalidArguments("Memory storage is unavailable on this device.") }
        let query = (call["query"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return PreparedAction(title: "Search memory", summary: query.isEmpty ? "Recent memories" : "“\(query)”",
                              icon: "brain", requiresConfirmation: false) {
            var found = query.isEmpty ? [] : database.searchMemories(query, limit: 5)
            if found.isEmpty && (query.isEmpty || MemorySearch.ftsQuery(query) == nil) {
                found = database.allMemories(limit: 10)
            }
            let f = DateFormatter()
            f.dateFormat = "MMM d, yyyy"
            return ToolOutcome(
                success: true,
                display: found.isEmpty ? "No saved memories match." : found.map { "• \($0.text)" }.joined(separator: "\n"),
                payload: .object([
                    ("status", .string("ok")),
                    ("memories", .array(found.map { .object([("text", .string($0.text)),
                                                             ("saved", .string(f.string(from: $0.createdAt)))]) })),
                ]))
        }
    }
}

struct DeleteMemoryTool: AssistantTool {
    let group = ToolGroup.memory
    let database: ChatDatabase?
    let spec = ToolSpec(
        name: "delete_memory",
        description: "Forget a fact the user previously asked you to remember.",
        parameters: Schema.object([
            ("query", Schema.string("A few words identifying the memory, e.g. 'peanut allergy'")),
        ], required: ["query"]))

    func prepare(_ call: ToolCall) async throws -> PreparedAction {
        guard let database else { throw ToolPreparationError.invalidArguments("Memory storage is unavailable on this device.") }
        let query = (call["query"] ?? call["text"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw ToolPreparationError.invalidArguments("Missing 'query'. Ask the user what to forget.") }
        if FuzzyMatch.isBulk(query) {
            throw ToolPreparationError.invalidArguments(
                "Only one memory can be deleted at a time here. The user can delete them all in the Memories screen.")
        }
        let candidates = database.searchMemories(query, limit: 5)
        let memory: Memory
        switch FuzzyMatch.best(query, in: candidates, name: \.text) {
        case .match(let m):
            memory = m
        case .none where candidates.count == 1:
            memory = candidates[0]
        case .none:
            throw ToolPreparationError.invalidArguments(candidates.isEmpty
                ? "No saved memory matches '\(query)'. Tell the user."
                : "Several memories partly match '\(query)': " + candidates.map { "'\($0.text)'" }.joined(separator: ", ") + ". Ask which one.")
        case .ambiguous(let ms):
            throw ToolPreparationError.invalidArguments(
                "Several memories match '\(query)': " + ms.map { "'\($0.text)'" }.joined(separator: ", ") + ". Ask which one.")
        }
        return PreparedAction(title: "Forget memory", summary: memory.text, icon: "brain",
                              requiresConfirmation: true, isDestructive: true) {
            do {
                try database.deleteMemory(id: memory.id)
                return ToolOutcome(success: true, display: "Forgot “\(memory.text)”",
                                   payload: .object([("status", .string("deleted")), ("text", .string(memory.text))]))
            } catch {
                return .failure("Deleting the memory failed: \(error.localizedDescription)")
            }
        }
    }
}
