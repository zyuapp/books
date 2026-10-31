import Foundation

/// One thing Claude can do in Books. Every tool is declared once here and served to Claude by `LocalToolServer`;
/// adding a capability means adding an `AgentTool` to a catalog in `AgentToolbox`.
struct AgentTool {
    enum Kind {
        /// Looks something up; changes nothing.
        case read
        /// Moves the reader; undone with Back.
        case navigate
        /// Changes the user's data or settings; always reported with Undo.
        case change
    }

    struct Parameter {
        enum ValueType: String { case string, integer, number, boolean, stringArray }
        let name: String
        let type: ValueType
        let description: String
        var required = false
        var options: [String]? = nil
    }

    let name: String
    let description: String
    let kind: Kind
    /// Shown in the chat while the tool runs, e.g. "Searching your highlights".
    let progress: String
    var parameters: [Parameter] = []
    let run: @MainActor (ToolArguments, AgentSession) async throws -> ToolResult

    /// JSON Schema for the tool's input.
    var inputSchema: [String: Any] {
        var properties: [String: Any] = [:]
        for p in parameters {
            var schema: [String: Any]
            switch p.type {
            case .stringArray: schema = ["type": "array", "items": ["type": "string"]]
            default: schema = ["type": p.type.rawValue]
            }
            schema["description"] = p.description
            if let options = p.options { schema["enum"] = options }
            properties[p.name] = schema
        }
        var result: [String: Any] = ["type": "object", "properties": properties]
        let required = parameters.filter(\.required).map(\.name)
        if !required.isEmpty { result["required"] = required }
        return result
    }
}

/// What a tool hands back: text for Claude, and for changes, a record the user sees (with Undo).
struct ToolResult {
    var text: String
    var activity: AgentActivity?

    static func text(_ text: String) -> ToolResult { ToolResult(text: text) }
}

/// A visible record of something Claude did, shown in the conversation.
struct AgentActivity: Identifiable {
    let id = UUID()
    var symbol: String
    var title: String
    var undoLabel = "Undo"
    var undo: (@MainActor () -> Void)?
}

enum ToolError: LocalizedError {
    case missing(String)
    case invalid(String)
    case notFound(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .missing(let name): "Missing required argument “\(name)”."
        case .invalid(let message), .notFound(let message), .unavailable(let message): message
        }
    }
}

/// Typed access to a tool call's JSON arguments.
struct ToolArguments {
    let raw: [String: Any]

    func string(_ key: String) -> String? {
        guard let s = raw[key] as? String else { return (raw[key] as? NSNumber)?.stringValue }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    func int(_ key: String) -> Int? {
        if let n = raw[key] as? NSNumber { return n.intValue }
        return (raw[key] as? String).flatMap { Int($0) }
    }

    func double(_ key: String) -> Double? {
        if let n = raw[key] as? NSNumber { return n.doubleValue }
        return (raw[key] as? String).flatMap { Double($0) }
    }

    func bool(_ key: String) -> Bool? {
        if let b = raw[key] as? Bool { return b }
        return (raw[key] as? String).map { ["true", "yes", "1"].contains($0.lowercased()) }
    }

    func strings(_ key: String) -> [String] {
        if let a = raw[key] as? [String] { return a.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        return string(key).map { [$0] } ?? []
    }

    func uuid(_ key: String) -> UUID? { string(key).flatMap(UUID.init(uuidString:)) }

    func require(_ key: String) throws -> String {
        guard let s = string(key) else { throw ToolError.missing(key) }
        return s
    }
}

/// The book and conversation a run of Claude belongs to.
@MainActor
final class AgentSession {
    weak var reader: ReaderModel?
    var onActivity: (AgentActivity) -> Void = { _ in }
    var onProgress: (String?) -> Void = { _ in }
    var lastSearch: [SearchResult] = []
    var lastSearchQuery = ""

    init(reader: ReaderModel) { self.reader = reader }

    func requireReader() throws -> ReaderModel {
        guard let reader, reader.publication != nil else { throw ToolError.unavailable("No book is open.") }
        return reader
    }
}
