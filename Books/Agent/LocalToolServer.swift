import Foundation
import Network

/// Serves Books' tools to the Claude Code CLI as an MCP server over HTTP on 127.0.0.1.
/// Each Claude run gets its own bearer token, which routes its calls to the reader that started it,
/// so nothing has to be installed or configured by the user.
@MainActor
final class LocalToolServer {
    static let shared = LocalToolServer()

    private var listener: NWListener?
    private var port: UInt16?
    private var sessions: [String: AgentSession] = [:]
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []

    /// Registers a session and returns the `--mcp-config` JSON that lets one Claude run reach it.
    func register(_ session: AgentSession) async -> (config: String, token: String)? {
        await start()
        guard let port else { return nil }
        let token = Self.randomToken()
        sessions[token] = session
        let config: [String: Any] = ["mcpServers": ["books": [
            "type": "http",
            "url": "http://127.0.0.1:\(port)/mcp",
            "headers": ["Authorization": "Bearer \(token)"],
        ]]]
        guard let data = try? JSONSerialization.data(withJSONObject: config) else { return nil }
        return (String(decoding: data, as: UTF8.self), token)
    }

    func unregister(_ token: String) { sessions[token] = nil }

    // MARK: Listener

    private func start() async {
        if port != nil { return }
        if listener == nil {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
            params.allowLocalEndpointReuse = true
            guard let l = try? NWListener(using: params) else { return }
            listener = l
            l.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.listenerChanged(state) }
            }
            l.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            l.start(queue: .main)
        }
        await withCheckedContinuation { readyWaiters.append($0) }
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            port = listener?.port?.rawValue
            resumeWaiters()
        case .failed, .cancelled:
            listener = nil
            port = nil
            resumeWaiters()
        default: break
        }
    }

    private func resumeWaiters() {
        let waiters = readyWaiters
        readyWaiters = []
        waiters.forEach { $0.resume() }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            Task { @MainActor in
                guard let self else { return }
                var buffer = buffer
                if let data { buffer.append(data) }
                if let request = HTTPRequest(buffer) {
                    let response = await self.respond(to: request)
                    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                } else if error != nil || done || buffer.count > 8 << 20 {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: buffer)
                }
            }
        }
    }

    // MARK: MCP over HTTP

    private func respond(to request: HTTPRequest) async -> Data {
        guard request.method == "POST" else { return HTTPRequest.response(status: "405 Method Not Allowed") }
        guard let token = request.bearerToken, let session = sessions[token] else {
            return HTTPRequest.response(status: "401 Unauthorized")
        }
        guard let json = try? JSONSerialization.jsonObject(with: request.body) else {
            return HTTPRequest.response(status: "400 Bad Request")
        }
        let messages = (json as? [[String: Any]]) ?? [(json as? [String: Any]) ?? [:]]
        var replies: [[String: Any]] = []
        for message in messages {
            guard let id = message["id"], let method = message["method"] as? String else { continue }
            let params = message["params"] as? [String: Any] ?? [:]
            replies.append(await reply(id: id, method: method, params: params, session: session))
        }
        guard !replies.isEmpty else { return HTTPRequest.response(status: "202 Accepted") }
        let payload: Any = json is [Any] ? replies : replies[0]
        let body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        return HTTPRequest.response(status: "200 OK", json: body)
    }

    private func reply(id: Any, method: String, params: [String: Any], session: AgentSession) async -> [String: Any] {
        func result(_ r: Any) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": r] }
        switch method {
        case "initialize":
            return result([
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "books", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"],
            ])
        case "tools/list":
            return result(["tools": AgentToolbox.all.map { tool -> [String: Any] in
                [
                    "name": tool.name,
                    "description": tool.description,
                    "inputSchema": tool.inputSchema,
                    "annotations": ["readOnlyHint": tool.kind == .read],
                ]
            }])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = ToolArguments(raw: params["arguments"] as? [String: Any] ?? [:])
            guard let tool = AgentToolbox.tool(named: name) else {
                return result(["content": [["type": "text", "text": "Unknown tool \(name)."]], "isError": true])
            }
            session.onProgress(tool.progress)
            defer { session.onProgress(nil) }
            do {
                let output = try await tool.run(args, session)
                if let activity = output.activity { session.onActivity(activity) }
                return result(["content": [["type": "text", "text": output.text]]])
            } catch {
                return result(["content": [["type": "text", "text": error.localizedDescription]], "isError": true])
            }
        default:
            return result([String: Any]())
        }
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// A complete HTTP/1.1 request parsed from a buffer, or nil while more bytes are needed.
private struct HTTPRequest {
    let method: String
    let headers: [String: String]
    let body: Data

    init?(_ data: Data) {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        lines.removeFirst()
        method = String(requestLine.split(separator: " ").first ?? "")
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        self.headers = headers
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = end.upperBound
        guard data.count - bodyStart >= length else { return nil }
        body = data.subdata(in: bodyStart..<(bodyStart + length))
    }

    var bearerToken: String? {
        guard let value = headers["authorization"], value.hasPrefix("Bearer ") else { return nil }
        return String(value.dropFirst(7))
    }

    static func response(status: String, json: Data? = nil) -> Data {
        var head = "HTTP/1.1 \(status)\r\nConnection: close\r\nContent-Length: \(json?.count ?? 0)\r\n"
        if json != nil { head += "Content-Type: application/json\r\n" }
        head += "\r\n"
        var data = Data(head.utf8)
        if let json { data.append(json) }
        return data
    }
}
