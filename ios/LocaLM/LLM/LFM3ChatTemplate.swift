import Foundation

/// A tool call proposed by the model. Arguments keep the order the model wrote them in,
/// so re-rendering the conversation reproduces the exact tokens (needed for cache reuse).
struct ToolCall: Equatable, Codable {
    var name: String
    var arguments: [Argument]

    struct Argument: Equatable, Codable {
        var name: String
        var value: String
    }

    subscript(_ key: String) -> String? {
        arguments.first(where: { $0.name == key })?.value
    }
}

struct PromptMessage: Equatable, Codable {
    enum Role: String, Codable { case user, assistant, tool }
    var role: Role
    var content: String
    var toolCalls: [ToolCall] = []
    var thinking: String? = nil

    static func user(_ text: String) -> PromptMessage { .init(role: .user, content: text) }
    static func tool(_ payload: String) -> PromptMessage { .init(role: .tool, content: payload) }
    static func assistant(_ text: String, toolCalls: [ToolCall] = [], thinking: String? = nil) -> PromptMessage {
        .init(role: .assistant, content: text, toolCalls: toolCalls, thinking: thinking)
    }
}

/// Ordered JSON value. Rendering matches Jinja's `tojson` (Python json.dumps defaults: ", " and ": "
/// separators, keys in insertion order), so tool schemas look exactly like what the model saw in training,
/// and the system prompt is byte-identical across turns.
indirect enum JSONValue: Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([(String, JSONValue)])

    static func == (lhs: JSONValue, rhs: JSONValue) -> Bool { lhs.rendered == rhs.rendered }

    var rendered: String {
        switch self {
        case .string(let s): return JSONValue.quote(s)
        case .number(let n):
            return n.rounded() == n && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .array(let items): return "[" + items.map(\.rendered).joined(separator: ", ") + "]"
        case .object(let pairs):
            return "{" + pairs.map { "\(JSONValue.quote($0.0)): \($0.1.rendered)" }.joined(separator: ", ") + "}"
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

/// A JSON-schema tool definition, rendered into the system prompt the way the LFM3 chat template does.
struct ToolSpec {
    var name: String
    var description: String
    var parameters: JSONValue

    /// Matches the template's tool_to_json(): {"name": ..., "description": ..., "parameters": ...}
    var jsonLine: String {
        JSONValue.object([
            ("name", .string(name)),
            ("description", .string(description)),
            ("parameters", parameters),
        ]).rendered
    }
}

/// Swift port of the chat template embedded in LFM3-1.7B's GGUF (tokenizer.chat_template).
/// Only the text-only subset we use is implemented: system + tools, user, assistant (+ tool calls), tool results.
enum LFM3ChatTemplate {
    static let bos = "<|startoftext|>"

    static func render(system: String,
                       tools: [ToolSpec],
                       messages: [PromptMessage],
                       enableThinking: Bool) -> String {
        var out = bos

        var systemPrompt = system
        if !tools.isEmpty {
            if !systemPrompt.isEmpty { systemPrompt += "\n\n" }
            systemPrompt += "<tools>\n" + tools.map(\.jsonLine).joined(separator: "\n") + "\n</tools>"
        }
        if !systemPrompt.isEmpty {
            out += "<|im_start|>system\n\(systemPrompt)<|im_end|>\n"
        }

        let lastUserIndex = messages.lastIndex(where: { $0.role == .user }) ?? -1

        for (index, message) in messages.enumerated() {
            switch message.role {
            case .user:
                out += "<|im_start|>user\n\(message.content)<|im_end|>\n"

            case .assistant:
                out += "<|im_start|>assistant\n"
                // Reasoning is kept only for assistant turns after the latest user message.
                let keepThinking = index > lastUserIndex
                var content = message.content
                if keepThinking {
                    if let thinking = message.thinking {
                        out += "<think>\(thinking)</think>"
                    } else if !content.contains("</think>") {
                        out += "<think></think>"
                    }
                } else {
                    if let range = content.range(of: "</think>", options: .backwards) {
                        content = String(content[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    content = "<think></think>" + content
                }
                out += content
                out += renderToolCalls(message.toolCalls)
                out += "<|im_end|>\n"

            case .tool:
                out += "<|im_start|>tool\n"
                if message.content.contains("<tool_response>") {
                    out += message.content
                } else {
                    out += "<tool_response>\n\(message.content)\n</tool_response>"
                }
                out += "<|im_end|>\n"
            }
        }

        out += "<|im_start|>assistant\n"
        out += enableThinking ? "<think>" : "<think></think>"
        return out
    }

    static func renderToolCalls(_ calls: [ToolCall]) -> String {
        calls.map { call in
            var s = "<tool_call>\n<function=\(call.name)>\n"
            for arg in call.arguments {
                s += "<parameter=\(arg.name)>\n\(arg.value)\n</parameter>\n"
            }
            s += "</function>\n</tool_call>"
            return s
        }.joined(separator: "\n\n")
    }
}
