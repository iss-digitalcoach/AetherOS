import Foundation

struct ToolSpec: Encodable, Sendable {
    struct Function: Encodable, Sendable {
        var name: String
        var description: String
        var parameters: JSONValue
    }
    var type = "function"
    var function: Function
}

protocol AgentTool: Sendable {
    var name: String { get }
    var description: String { get }
    var parameters: JSONValue { get }
    /// Mutating tools must return true so the user approves each call.
    var requiresConfirmation: Bool { get }
    /// Web tools can be switched off as a group in Settings.
    var isWeb: Bool { get }
    /// Per-call override; lets a tool ask only for risky arguments.
    func needsConfirmation(_ args: [String: JSONValue]) async -> Bool
    func summarize(_ args: [String: JSONValue]) -> String
    func run(_ args: [String: JSONValue]) async throws -> String
}

extension AgentTool {
    var isWeb: Bool { false }
    func needsConfirmation(_ args: [String: JSONValue]) async -> Bool { requiresConfirmation }
    var spec: ToolSpec { .init(function: .init(name: name, description: description, parameters: parameters)) }
}

enum ToolError: LocalizedError {
    case missing(String), outsideSandbox(String), exists(String)
    var errorDescription: String? {
        switch self {
        case .missing(let k): "missing argument '\(k)'"
        case .outsideSandbox(let p): "path is outside the allowed folders: \(p)"
        case .exists(let p): "destination already exists: \(p)"
        }
    }
}

/// File tools are confined to the user's home directory and never follow into system folders.
enum PathGuard {
    static func resolve(_ raw: String) throws -> URL {
        let expanded = (raw as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath()
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        guard url.path == home || url.path.hasPrefix(home + "/") else { throw ToolError.outsideSandbox(raw) }
        return url
    }
}

private func schema(_ props: [String: String], required: [String]) -> JSONValue {
    .object([
        "type": .string("object"),
        "properties": .object(props.mapValues { .object(["type": .string("string"), "description": .string($0)]) }),
        "required": .array(required.map { .string($0) }),
    ])
}

struct ListDirectoryTool: AgentTool {
    let name = "list_directory"
    let description = "List files and folders in a directory inside the user's home folder."
    let requiresConfirmation = false
    var parameters: JSONValue { schema(["path": "Directory path, e.g. ~/Documents"], required: ["path"]) }
    func summarize(_ a: [String: JSONValue]) -> String { "List \(a["path"]?.stringValue ?? "?")" }

    func run(_ a: [String: JSONValue]) async throws -> String {
        guard let p = a["path"]?.stringValue else { throw ToolError.missing("path") }
        let url = try PathGuard.resolve(p)
        let items = try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        return items.prefix(200).map { u in
            let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return u.lastPathComponent + (isDir ? "/" : "")
        }.sorted().joined(separator: "\n")
    }
}

struct ReadTextFileTool: AgentTool {
    let name = "read_text_file"
    let description = "Read up to 20 KB of a UTF-8 text file inside the user's home folder."
    let requiresConfirmation = false
    var parameters: JSONValue { schema(["path": "File path"], required: ["path"]) }
    func summarize(_ a: [String: JSONValue]) -> String { "Read \(a["path"]?.stringValue ?? "?")" }

    func run(_ a: [String: JSONValue]) async throws -> String {
        guard let p = a["path"]?.stringValue else { throw ToolError.missing("path") }
        let handle = try FileHandle(forReadingFrom: try PathGuard.resolve(p))
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 20_000) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

struct RenameItemTool: AgentTool {
    let name = "rename_item"
    let description = "Rename or move a file or folder within the user's home folder. Fails if the destination exists."
    let requiresConfirmation = true
    var parameters: JSONValue { schema(["from": "Existing path", "to": "New path"], required: ["from", "to"]) }
    func summarize(_ a: [String: JSONValue]) -> String {
        "Rename \(a["from"]?.stringValue ?? "?") → \(a["to"]?.stringValue ?? "?")"
    }

    func run(_ a: [String: JSONValue]) async throws -> String {
        guard let f = a["from"]?.stringValue else { throw ToolError.missing("from") }
        guard let t = a["to"]?.stringValue else { throw ToolError.missing("to") }
        let src = try PathGuard.resolve(f), dst = try PathGuard.resolve(t)
        guard !FileManager.default.fileExists(atPath: dst.path) else { throw ToolError.exists(t) }
        try FileManager.default.moveItem(at: src, to: dst)
        return "ok"
    }
}

enum DefaultTools {
    static let web = WebSession()
    static let all: [any AgentTool] = [
        ListDirectoryTool(), ReadTextFileTool(), RenameItemTool(),
        WebSearchTool(session: web), FetchURLTool(session: web),
    ]
}
