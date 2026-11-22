import Foundation
import OSLog

enum ChatGPTEvent: Sendable {
    case text(String)
    /// ChatGPT started a web search.
    case searching
    case finished
}

enum ChatGPTError: LocalizedError {
    case usageLimit
    case notEligible
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .usageLimit: "You’ve reached a usage limit for your ChatGPT plan or for Books. Review your plan or Books’ limit in ChatGPT settings."
        case .notEligible: "ChatGPT plan usage isn’t available for this account or workspace."
        case .failed(let message): message
        }
    }
}

/// Runs one answer through the Responses API with the reader's ChatGPT plan,
/// executing Books' tools locally whenever the model calls them.
@MainActor
enum ChatGPTService {
    private static let log = Logger(subsystem: "com.zyu.books", category: "ChatGPT")

    /// `input` holds the conversation as Responses input items, ending with the reader's question.
    static func stream(input: [[String: Any]], instructions: String, model: String, effort: String,
                       session: AgentSession?) -> AsyncThrowingStream<ChatGPTEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    try await run(input: input, instructions: instructions, model: model, effort: effort, session: session) {
                        continuation.yield($0)
                    }
                    continuation.yield(.finished)
                    continuation.finish()
                } catch let error as APIError {
                    let failure = error.asChatGPTError
                    if case .usageLimit = failure { ChatGPTAccount.shared.usageLimitReached = true }
                    continuation.finish(throwing: failure)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static let maxRounds = 30

    private static func run(input: [[String: Any]], instructions: String, model: String, effort: String,
                            session: AgentSession?, emit: (ChatGPTEvent) -> Void) async throws {
        var input = input
        var wroteText = false
        var webSearch = true
        for _ in 0..<maxRounds {
            try Task.checkCancellation()
            var body: [String: Any] = [
                "model": model,
                "instructions": instructions,
                "input": input,
                "tools": tools(includeBooks: session != nil, webSearch: webSearch),
                "tool_choice": "auto",
                "parallel_tool_calls": false,
                "store": false,
                "stream": true,
                "include": ["reasoning.encrypted_content"],
            ]
            if !effort.isEmpty { body["reasoning"] = ["effort": effort] }
            let round: Round
            do {
                round = try await send(body, separate: wroteText, emit: emit)
            } catch let error as APIError where webSearch && error.rejectsWebSearch {
                webSearch = false
                continue
            }
            wroteText = wroteText || round.wroteText
            input += round.items
            let calls = round.items.filter { $0["type"] as? String == "function_call" }
            guard !calls.isEmpty, let session else { return }
            for call in calls {
                let output = await AgentToolbox.call(name: call["name"] as? String ?? "", arguments: call["arguments"] as? String ?? "{}",
                                                     session: session)
                input.append(["type": "function_call_output", "call_id": call["call_id"] as? String ?? "", "output": output])
            }
        }
        throw ChatGPTError.failed("ChatGPT kept using tools without answering. Try asking again.")
    }

    private static func tools(includeBooks: Bool, webSearch: Bool) -> [[String: Any]] {
        var tools: [[String: Any]] = webSearch ? [["type": "web_search"]] : []
        if includeBooks {
            tools.insert([
                "type": "namespace",
                "name": "books",
                "description": "Tools that read and act inside the Books reading app.",
                "tools": AgentToolbox.all.map { tool -> [String: Any] in
                    ["type": "function", "name": tool.name, "description": tool.description, "parameters": tool.inputSchema, "strict": false]
                },
            ], at: 0)
        }
        return tools
    }

    private struct Round {
        var items: [[String: Any]] = []
        var wroteText = false
    }

    /// Sends one request and reads its event stream through the terminal event.
    private static func send(_ body: [String: Any], separate: Bool, emit: (ChatGPTEvent) -> Void) async throws -> Round {
        let account = ChatGPTAccount.shared
        let payload = try JSONSerialization.data(withJSONObject: body)
        var retriedAuth = false
        while true {
            var request = URLRequest(url: ChatGPTAccount.Endpoint.responses)
            request.httpMethod = "POST"
            request.httpBody = payload
            request.timeoutInterval = 300
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(try await account.accessToken(force: retriedAuth))", forHTTPHeaderField: "Authorization")
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status != 200 {
                var data = Data()
                for try await byte in bytes {
                    data.append(byte)
                    if data.count > 65536 { break }
                }
                let error = apiError(status: status, body: data)
                log.error("Responses error \(status) \(error.code ?? "-", privacy: .public): \(error.message ?? "-", privacy: .public)")
                if status == 401, !retriedAuth, error.code != "subscription_sharing_invalid_user" {
                    retriedAuth = true
                    continue
                }
                if status == 401 { account.sessionEnded() }
                throw error
            }

            var round = Round()
            var separate = separate
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard let event = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                      let type = event["type"] as? String else { continue }
                switch type {
                case "response.output_text.delta":
                    guard let delta = event["delta"] as? String, !delta.isEmpty else { continue }
                    if separate { emit(.text("\n\n")); separate = false }
                    round.wroteText = true
                    emit(.text(delta))
                case "response.output_item.added":
                    let item = event["item"] as? [String: Any]
                    if item?["type"] as? String == "web_search_call" { emit(.searching) }
                    if item?["type"] as? String == "message", round.wroteText || separate { separate = true }
                case "response.output_item.done":
                    if let item = event["item"] as? [String: Any] { round.items.append(item) }
                case "response.completed", "response.incomplete":
                    return round
                case "response.failed":
                    let failure = (event["response"] as? [String: Any])?["error"] as? [String: Any]
                    throw APIError(status: 0, code: failure?["code"] as? String, message: failure?["message"] as? String,
                                   param: failure?["param"] as? String)
                case "error":
                    let failure = event["error"] as? [String: Any] ?? event
                    throw APIError(status: 0, code: failure["code"] as? String, message: failure["message"] as? String,
                                   param: failure["param"] as? String)
                default:
                    break
                }
            }
            try Task.checkCancellation()
            throw ChatGPTError.failed("The connection to ChatGPT ended before the answer finished. Try again.")
        }
    }

    private struct APIError: Error {
        var status: Int
        var code: String?
        var message: String?
        var param: String? = nil

        var rejectsWebSearch: Bool {
            code == "subscription_sharing_unsupported_capability" && (param ?? "").contains("tools")
        }

        var asChatGPTError: ChatGPTError {
            switch code {
            case "subscription_sharing_usage_limit_exceeded": return .usageLimit
            case "subscription_sharing_user_not_eligible": return .notEligible
            case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable":
                return .failed("ChatGPT is temporarily unavailable. Try again in a moment.")
            default:
                if status == 429 { return .usageLimit }
                let detail = message ?? (status == 0 ? "ChatGPT couldn’t finish the answer." : "ChatGPT returned HTTP \(status).")
                return .failed(code.map { "\(detail) (\($0))" } ?? detail)
            }
        }
    }

    private static func apiError(status: Int, body: Data) -> APIError {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        if let error = json?["error"] as? [String: Any] {
            return APIError(status: status, code: error["code"] as? String, message: error["message"] as? String, param: error["param"] as? String)
        }
        let text = json?["detail"] as? String ?? String(decoding: body.prefix(400), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return APIError(status: status, code: nil, message: text.isEmpty ? nil : text)
    }
}
