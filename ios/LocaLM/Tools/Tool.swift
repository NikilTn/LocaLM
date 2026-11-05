import Foundation

/// What the app shows and what the model is told after a tool runs.
/// `payload` goes back to the model; the UI card is built from `success` and `display`,
/// so the user never sees "done" unless the code actually did it.
struct ToolOutcome {
    var success: Bool
    var display: String
    var payload: JSONValue
    /// Optional source links shown on the action card (e.g. web search results).
    var links: [ToolCard.LinkItem]? = nil
    /// An app to open (Maps, Phone, Shortcuts) after the model's reply is finished.
    var openAfterReply: URL? = nil

    static func failure(_ message: String) -> ToolOutcome {
        ToolOutcome(success: false, display: message,
                    payload: .object([("status", .string("error")), ("message", .string(message))]))
    }
}

/// A validated, ready-to-run action. Created by the tool from the model's raw arguments.
struct PreparedAction {
    var title: String               // e.g. "Create reminder"
    var summary: String             // e.g. "Email professor · Thu, Oct 29 at 8:00 AM"
    var icon: String                // SF Symbol for the card
    var requiresConfirmation: Bool
    var isDestructive = false       // red Confirm button (deletes)
    var run: () async -> ToolOutcome
}

enum ToolPreparationError: Error {
    /// Arguments are missing, invalid, or match nothing. The message goes back to the model so it can
    /// ask the user or explain. Nothing is shown as an action card.
    case invalidArguments(String)
}

/// Tools are offered to the model in groups, chosen by ToolRouter from the user's wording.
enum ToolGroup: String, CaseIterable, Codable {
    case reminders, calendar, memory, alarms, contacts, maps, shortcuts, utilities, device, web
}

protocol AssistantTool {
    var spec: ToolSpec { get }
    var group: ToolGroup { get }
    /// Validate and normalize the model's arguments in code, and look up anything the confirmation
    /// card needs (matching reminder, calendar conflicts). Never trust the arguments as-is.
    func prepare(_ call: ToolCall) async throws -> PreparedAction
}

/// Holds the tools the model may see. Unknown tool names from the model are rejected here.
struct ToolRegistry {
    let tools: [AssistantTool]

    var specs: [ToolSpec] { tools.map(\.spec) }

    func tool(named name: String) -> AssistantTool? {
        tools.first(where: { $0.spec.name == name })
    }

    func filtered(to groups: Set<ToolGroup>) -> ToolRegistry {
        ToolRegistry(tools: tools.filter { groups.contains($0.group) })
    }
}

/// Small helpers for building JSON-schema parameter objects.
enum Schema {
    static func object(_ properties: [(String, JSONValue)], required: [String]) -> JSONValue {
        .object([
            ("type", .string("object")),
            ("properties", .object(properties)),
            ("required", .array(required.map { .string($0) })),
        ])
    }

    static func string(_ description: String) -> JSONValue {
        .object([("type", .string("string")), ("description", .string(description))])
    }
}
