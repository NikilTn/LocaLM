import Foundation
import SQLite3

/// Local chat storage in SQLite (Application Support/LocaLM/chat.sqlite).
/// Two streams per conversation:
///   - prompt_messages: what the model sees (user / assistant + tool calls / tool results)
///   - chat_items:      what the UI shows (bubbles, tool cards, errors)
/// Rows hold Codable JSON plus plain role/text columns for future search.
final class ChatDatabase {
    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    struct SQLiteError: LocalizedError {
        var errorDescription: String?
    }

    static func defaultURL() throws -> URL {
        let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                              appropriateFor: nil, create: true)
            .appendingPathComponent("LocaLM", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            // Files created inside inherit the protection class: unreadable while the phone is locked,
            // except files already open (so an in-flight write can finish).
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUnlessOpen])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true // chats stay on this device, not in iCloud backups
            var mutable = dir
            try mutable.setResourceValues(values)
        }
        return dir.appendingPathComponent("chat.sqlite")
    }

    init(url: URL) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            throw SQLiteError(errorDescription: "Could not open chat database: \(message)")
        }
        try exec("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;")
        try exec("""
        CREATE TABLE IF NOT EXISTS conversations(
            id TEXT PRIMARY KEY,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS prompt_messages(
            conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
            seq INTEGER NOT NULL,
            role TEXT NOT NULL,
            text TEXT NOT NULL,
            json TEXT NOT NULL,
            created_at REAL NOT NULL,
            PRIMARY KEY(conversation_id, seq));
        CREATE TABLE IF NOT EXISTS chat_items(
            id TEXT PRIMARY KEY,
            conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
            seq INTEGER NOT NULL,
            json TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS chat_items_by_conversation ON chat_items(conversation_id, seq);
        CREATE VIRTUAL TABLE IF NOT EXISTS memories USING fts5(
            id UNINDEXED,
            text,
            created_at UNINDEXED,
            source UNINDEXED,
            tokenize = 'porter unicode61');
        """)
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: Conversations

    func latestConversationID() -> String? {
        query("SELECT id FROM conversations ORDER BY updated_at DESC LIMIT 1") { stmt in
            String(cString: sqlite3_column_text(stmt, 0))
        }.first
    }

    func createConversation() throws -> String {
        let id = UUID().uuidString
        let now = Date().timeIntervalSince1970
        try run("INSERT INTO conversations(id, created_at, updated_at) VALUES(?, ?, ?)", [.text(id), .real(now), .real(now)])
        return id
    }

    func deleteConversation(_ id: String) throws {
        try run("DELETE FROM conversations WHERE id = ?", [.text(id)])
    }

    private func touch(_ conversationID: String) throws {
        try run("UPDATE conversations SET updated_at = ? WHERE id = ?",
                [.real(Date().timeIntervalSince1970), .text(conversationID)])
    }

    // MARK: Prompt messages

    func promptMessages(in conversationID: String) -> [PromptMessage] {
        query("SELECT json FROM prompt_messages WHERE conversation_id = ? ORDER BY seq", [.text(conversationID)]) { stmt in
            let json = String(cString: sqlite3_column_text(stmt, 0))
            return try? self.decoder.decode(PromptMessage.self, from: Data(json.utf8))
        }.compactMap { $0 }
    }

    func appendPromptMessage(_ message: PromptMessage, seq: Int, in conversationID: String) throws {
        let json = String(decoding: try encoder.encode(message), as: UTF8.self)
        try run("INSERT INTO prompt_messages(conversation_id, seq, role, text, json, created_at) VALUES(?, ?, ?, ?, ?, ?)",
                [.text(conversationID), .int(seq), .text(message.role.rawValue), .text(message.content),
                 .text(json), .real(Date().timeIntervalSince1970)])
        try touch(conversationID)
    }

    // MARK: Chat items

    func chatItems(in conversationID: String) -> [(item: ChatItem, seq: Int)] {
        query("SELECT json, seq FROM chat_items WHERE conversation_id = ? ORDER BY seq", [.text(conversationID)]) { stmt in
            let json = String(cString: sqlite3_column_text(stmt, 0))
            let seq = Int(sqlite3_column_int64(stmt, 1))
            return (try? self.decoder.decode(ChatItem.self, from: Data(json.utf8))).map { ($0, seq) }
        }.compactMap { $0 }
    }

    func upsertChatItem(_ item: ChatItem, seq: Int, in conversationID: String) throws {
        let json = String(decoding: try encoder.encode(item), as: UTF8.self)
        try run("""
            INSERT INTO chat_items(id, conversation_id, seq, json) VALUES(?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET json = excluded.json, seq = excluded.seq
            """, [.text(item.id.uuidString), .text(conversationID), .int(seq), .text(json)])
    }

    func deleteChatItem(_ id: UUID) throws {
        try run("DELETE FROM chat_items WHERE id = ?", [.text(id.uuidString)])
    }

    // MARK: Memories (FTS5 full-text index; porter stemming so "birthdays" finds "birthday")

    @discardableResult
    func addMemory(_ text: String, source: String = "user", createdAt: Date = Date()) throws -> Memory {
        let memory = Memory(id: UUID().uuidString, text: text, createdAt: createdAt, source: source)
        try run("INSERT INTO memories(id, text, created_at, source) VALUES(?, ?, ?, ?)",
                [.text(memory.id), .text(text), .real(createdAt.timeIntervalSince1970), .text(source)])
        return memory
    }

    func updateMemory(id: String, text: String) throws {
        try run("UPDATE memories SET text = ? WHERE id = ?", [.text(text), .text(id)])
    }

    func deleteMemory(id: String) throws {
        try run("DELETE FROM memories WHERE id = ?", [.text(id)])
    }

    func allMemories(limit: Int = 500) -> [Memory] {
        query("SELECT id, text, created_at, source FROM memories ORDER BY CAST(created_at AS REAL) DESC LIMIT ?",
              [.int(limit)], row: Self.memoryRow)
    }

    /// Best matches first. Empty when the text has no searchable words.
    func searchMemories(_ text: String, limit: Int = 5) -> [Memory] {
        guard let match = MemorySearch.ftsQuery(text) else { return [] }
        return query("SELECT id, text, created_at, source FROM memories WHERE memories MATCH ? ORDER BY bm25(memories) LIMIT ?",
                     [.text(match), .int(limit)], row: Self.memoryRow)
    }

    private static func memoryRow(_ stmt: OpaquePointer) -> Memory {
        Memory(id: String(cString: sqlite3_column_text(stmt, 0)),
               text: String(cString: sqlite3_column_text(stmt, 1)),
               createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
               source: String(cString: sqlite3_column_text(stmt, 3)))
    }

    // MARK: SQLite helpers

    enum Value {
        case text(String)
        case int(Int)
        case real(Double)
    }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(err)
            throw SQLiteError(errorDescription: message)
        }
    }

    private func prepare(_ sql: String, _ values: [Value]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SQLiteError(errorDescription: String(cString: sqlite3_errmsg(db)))
        }
        for (i, value) in values.enumerated() {
            let index = Int32(i + 1)
            switch value {
            case .text(let s): sqlite3_bind_text(stmt, index, s, -1, Self.transient)
            case .int(let n): sqlite3_bind_int64(stmt, index, Int64(n))
            case .real(let d): sqlite3_bind_double(stmt, index, d)
            }
        }
        return stmt
    }

    private func run(_ sql: String, _ values: [Value] = []) throws {
        let stmt = try prepare(sql, values)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SQLiteError(errorDescription: String(cString: sqlite3_errmsg(db)))
        }
    }

    private func query<T>(_ sql: String, _ values: [Value] = [], row: (OpaquePointer) -> T) -> [T] {
        guard let stmt = try? prepare(sql, values) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(row(stmt)) }
        return out
    }
}
