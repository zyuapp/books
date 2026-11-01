import Foundation

enum ClaudeModel: String, CaseIterable, Identifiable {
    case sonnet, opus, haiku

    var id: String { rawValue }
    var name: String {
        switch self {
        case .sonnet: "Sonnet"
        case .opus: "Opus"
        case .haiku: "Haiku"
        }
    }
    var symbol: String {
        switch self {
        case .sonnet: "sparkle"
        case .opus: "brain"
        case .haiku: "bolt"
        }
    }
    var detail: String {
        switch self {
        case .sonnet: "Fast and thoughtful"
        case .opus: "Deepest reading"
        case .haiku: "Quickest answers"
        }
    }
}

enum ClaudeEffort: String, CaseIterable, Identifiable {
    case low, medium, high, xhigh, max

    var id: String { rawValue }
    var name: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "Extra High"
        case .max: "Max"
        }
    }
    var detail: String {
        switch self {
        case .low: "Quickest replies"
        case .medium: "Balanced"
        case .high: "Thinks it through"
        case .xhigh: "Thinks longer"
        case .max: "Thinks hardest, slowest"
        }
    }
}

enum ClaudeEvent: Sendable {
    case text(String)
    /// Claude started calling a tool, by name.
    case tool(String)
    case finished
}

enum ClaudeError: LocalizedError {
    case notInstalled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            "Claude Code isn’t installed. Install it, then run `claude` once in Terminal to sign in with your Claude subscription."
        case .failed(let message): message
        }
    }
}

/// Talks to Claude through the locally installed Claude Code CLI in headless mode,
/// so questions use the user's Claude subscription sign-in.
enum ClaudeService {
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cached: (custom: String, url: URL)?

    /// Locates the `claude` binary; the result is cached per custom-path setting.
    static func executable() -> URL? {
        let custom = UserDefaults.standard.string(forKey: "claudePath") ?? ""
        cacheLock.lock()
        if let cached, cached.custom == custom, FileManager.default.isExecutableFile(atPath: cached.url.path) {
            cacheLock.unlock()
            return cached.url
        }
        cacheLock.unlock()
        guard let url = locate(custom: custom) else { return nil }
        cacheLock.lock()
        cached = (custom, url)
        cacheLock.unlock()
        return url
    }

    private static func locate(custom: String) -> URL? {
        let fm = FileManager.default
        if !custom.isEmpty, fm.isExecutableFile(atPath: custom) { return URL(fileURLWithPath: custom) }
        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude", "\(home)/.npm-global/bin/claude", "\(home)/.bun/bin/claude",
        ]
        if let path = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) { return URL(fileURLWithPath: path) }
        // Fall back to the login shell's PATH.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v claude"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return fm.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    private static let webTools = "WebSearch,WebFetch"

    private static var workingDirectory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.zyu.books/Claude", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `toolsConfig` is `--mcp-config` JSON for Books' own tools; besides those, Claude gets only web search and fetch.
    static func stream(prompt: String, system: String, model: ClaudeModel, effort: ClaudeEffort, toolsConfig: String? = nil) -> AsyncThrowingStream<ClaudeEvent, Error> {
        AsyncThrowingStream { continuation in
            let process = Process()
            let cancelled = LockedFlag()
            continuation.onTermination = { _ in
                cancelled.set()
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global(qos: .userInitiated).async {
                guard let exe = executable() else {
                    continuation.finish(throwing: ClaudeError.notInstalled)
                    return
                }
                process.executableURL = exe
                process.currentDirectoryURL = workingDirectory
                process.arguments = [
                    "-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                    "--tools", webTools, "--setting-sources", "", "--no-session-persistence", "--disable-slash-commands",
                    "--model", model.rawValue, "--effort", effort.rawValue, "--system-prompt", system, "--strict-mcp-config",
                ]
                if let toolsConfig {
                    process.arguments! += ["--mcp-config", toolsConfig, "--allowedTools", "mcp__books," + webTools]
                } else {
                    process.arguments! += ["--allowedTools", webTools]
                }
                var env = ProcessInfo.processInfo.environment
                let extraPath = ["\(NSHomeDirectory())/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
                env["PATH"] = (extraPath + [env["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
                process.environment = env

                let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
                process.standardInput = stdin
                process.standardOutput = stdout
                process.standardError = stderr
                if cancelled.isSet { continuation.finish(); return }
                do {
                    try process.run()
                } catch {
                    continuation.finish(throwing: ClaudeError.failed(error.localizedDescription))
                    return
                }

                let group = DispatchGroup()
                let errBuffer = LockedData()
                DispatchQueue.global(qos: .utility).async(group: group) {
                    errBuffer.append(stderr.fileHandleForReading.readDataToEndOfFile())
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    try? stdin.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
                    try? stdin.fileHandleForWriting.close()
                }

                // Read stdout to EOF on this thread so lines arrive in order.
                let parser = StreamParser(continuation: continuation)
                let reader = stdout.fileHandleForReading
                while true {
                    let chunk = reader.availableData
                    if chunk.isEmpty { break }
                    parser.feed(chunk)
                }
                parser.flush()
                process.waitUntilExit()
                group.wait()
                if parser.didFinish { return }
                if cancelled.isSet || process.terminationReason == .uncaughtSignal {
                    continuation.finish()
                    return
                }
                let err = String(decoding: errBuffer.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.finish(throwing: ClaudeError.failed(err.isEmpty ? "Claude exited with status \(process.terminationStatus)." : err))
            }
        }
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    func append(_ d: Data) { lock.lock(); buffer.append(d); lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return buffer }
}

/// Parses Claude Code's newline-delimited stream-json output.
private final class StreamParser: @unchecked Sendable {
    private let continuation: AsyncThrowingStream<ClaudeEvent, Error>.Continuation
    private let lock = NSLock()
    private var buffer = Data()
    private var sawDelta = false
    private(set) var didFinish = false

    init(continuation: AsyncThrowingStream<ClaudeEvent, Error>.Continuation) {
        self.continuation = continuation
    }

    func feed(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            handle(line)
        }
    }

    func flush() {
        lock.lock()
        defer { lock.unlock() }
        if !buffer.isEmpty { handle(buffer); buffer.removeAll() }
    }

    private func handle(_ line: Data) {
        guard !didFinish, let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "stream_event":
            if let event = obj["event"] as? [String: Any], event["type"] as? String == "content_block_start",
               let block = event["content_block"] as? [String: Any], block["type"] as? String == "tool_use",
               let name = block["name"] as? String {
                continuation.yield(.tool(name))
                return
            }
            // Text resumes in a new block after a tool call; keep paragraphs apart.
            if let event = obj["event"] as? [String: Any], event["type"] as? String == "content_block_start",
               (event["content_block"] as? [String: Any])?["type"] as? String == "text", sawDelta {
                continuation.yield(.text("\n\n"))
                return
            }
            guard let event = obj["event"] as? [String: Any], event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String else { return }
            sawDelta = true
            continuation.yield(.text(text))
        case "assistant":
            // Without partial messages, the whole text arrives here.
            guard !sawDelta, let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return }
            let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
            if !text.isEmpty { continuation.yield(.text(text)) }
        case "result":
            didFinish = true
            if obj["is_error"] as? Bool == true {
                let message = obj["result"] as? String ?? "Claude returned an error."
                continuation.finish(throwing: ClaudeError.failed(message))
            } else {
                continuation.yield(.finished)
                continuation.finish()
            }
        default:
            break
        }
    }
}
