import Darwin
import Foundation

public enum AppServerError: LocalizedError, Equatable, Sendable {
    case unavailable, protocolError, timedOut, disconnected, accountChanged, cardUnavailable, busy
    public var errorDescription: String? {
        switch self {
        case .unavailable: L10n.text("未找到兼容的 Codex，请安装或更新 Codex CLI / Codex App。")
        case .protocolError: L10n.text("Codex 协议请求失败，请刷新或检查登录状态。")
        case .timedOut: L10n.text("Codex 请求超时。")
        case .disconnected: L10n.text("Codex 连接已中断。")
        case .accountChanged: L10n.text("账号身份已变化，请重新选择账号。")
        case .cardUnavailable: L10n.text("此重置卡已不可用，请刷新。")
        case .busy: L10n.text("此账号已有操作正在进行，请稍后重试。")
        }
    }
}

public actor CodexRuntime {
    public static let shared = CodexRuntime()
    private var validated: Set<String> = []

    public static func candidates(environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        let paths = (environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/codex" }
        let fallback = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex").path,
                        "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                        "/Applications/Codex.app/Contents/Resources/codex",
                        "/Applications/ChatGPT.app/Contents/Resources/codex"]
        var seen = Set<String>()
        return (paths + fallback).compactMap {
            let url = URL(fileURLWithPath: $0).resolvingSymlinksInPath()
            return seen.insert(url.path).inserted && FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
    }

    /// Probe the actual binary, not a guessed minimum version. No server or account is opened.
    public func resolve(candidates: [URL] = CodexRuntime.candidates()) async throws -> URL {
        for url in candidates {
            try Task.checkCancellation()
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let key = "\(url.path):\(attrs?[.modificationDate] ?? ""): \(attrs?[.size] ?? "")"
            if validated.contains(key) { return url }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("orb-schema-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            do {
                let result = try await CLIUpdateProcess.run(url, arguments: ["app-server", "generate-json-schema", "--out", directory.path], timeout: 15)
                guard result.status == 0 else { continue }
                func schema(_ name: String) throws -> [String: Any] {
                    let data = try Data(contentsOf: directory.appendingPathComponent("v2/\(name).json"))
                    return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                }
                let read = try schema("GetAccountRateLimitsResponse")
                let params = try schema("ConsumeAccountRateLimitResetCreditParams")
                let response = try schema("ConsumeAccountRateLimitResetCreditResponse")
                let properties = read["properties"] as? [String: Any] ?? [:]
                let definitions = read["definitions"] as? [String: Any] ?? [:]
                let credit = definitions["RateLimitResetCredit"] as? [String: Any] ?? [:]
                let fields = params["properties"] as? [String: Any] ?? [:]
                guard properties["rateLimitResetCredits"] != nil,
                      (credit["properties"] as? [String: Any])?["id"] != nil,
                      fields["idempotencyKey"] != nil, fields["creditId"] != nil,
                      (response["properties"] as? [String: Any])?["outcome"] != nil else { continue }
                validated.insert(key)
                return url
            } catch { continue }
        }
        throw AppServerError.unavailable
    }
}

final class ServerCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.withLock { value = true } }
    func check() throws { if lock.withLock({ value }) { throw CancellationError() } }
}

/// Confined to one worker thread. No model turns, shared daemon, or logout calls.
final class AppServerConnection {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private var nextID = 0
    private let cancellation: ServerCancellation
    private let timeout: TimeInterval

    init(executable: URL, account: CodexAccount, cancellation: ServerCancellation, timeout: TimeInterval) throws {
        self.cancellation = cancellation
        self.timeout = timeout
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio", "-c", "cli_auth_credentials_store=\"file\""]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = account.home
        process.environment = environment
        // Avoid loading the caller's repository configuration.
        process.currentDirectoryURL = URL(fileURLWithPath: account.home)
        process.standardInput = input
        process.standardOutput = output
        // Never persist upstream logs, which may contain account information.
        process.standardError = FileHandle.nullDevice
        try process.run()
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        let fd = output.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    func start(account: CodexAccount) throws {
        _ = try request("initialize", params: ["clientInfo": ["name": "codexorb", "version": "1.0.0"]])
        try send(["method": "initialized"])
        let result = try request("account/read", params: ["refreshToken": false])
        guard let user = result["account"] as? [String: Any], user["type"] as? String == "chatgpt",
              (user["email"] as? String)?.lowercased() == account.email.lowercased() else {
            throw AppServerError.accountChanged
        }
    }

    func send(_ object: [String: Any]) throws {
        try cancellation.check()
        guard process.isRunning else { throw AppServerError.disconnected }
        let data = try JSONSerialization.data(withJSONObject: object) + Data([10])
        do { try input.fileHandleForWriting.write(contentsOf: data) }
        catch { throw AppServerError.disconnected }
    }

    func request(_ method: String, params: [String: Any] = [:]) throws -> [String: Any] {
        nextID += 1
        let id = nextID
        try send(["id": id, "method": method, "params": params])
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var bytesRead = 0
        while true {
            try cancellation.check()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw AppServerError.timedOut }
            while let newline = buffer.firstIndex(of: 10) {
                let line = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw AppServerError.protocolError
                }
                if object["method"] != nil {
                    // Notifications may interleave with responses; reject unsolicited server requests.
                    if let serverID = object["id"] {
                        try send(["id": serverID, "error": ["code": -32601, "message": "Unsupported client method"]])
                    }
                    continue
                }
                guard (object["id"] as? Int) == id else { throw AppServerError.protocolError }
                guard object["error"] == nil, let result = object["result"] as? [String: Any] else {
                    throw AppServerError.protocolError
                }
                return result
            }
            var bytes = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(output.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
            if count > 0 {
                bytesRead += count
                guard bytesRead <= 2_097_152 else { throw AppServerError.protocolError }
                buffer.append(contentsOf: bytes.prefix(count))
            } else if count == 0 { throw AppServerError.disconnected }
            else if errno != EAGAIN && errno != EINTR { throw AppServerError.disconnected }
            else { Thread.sleep(forTimeInterval: 0.01) }
        }
    }

    func close() {
        try? input.fileHandleForWriting.close()
        let deadline = ProcessInfo.processInfo.systemUptime + 0.3
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { process.terminate() }
        let killDeadline = ProcessInfo.processInfo.systemUptime + 0.5
        while process.isRunning && ProcessInfo.processInfo.systemUptime < killDeadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        try? output.fileHandleForReading.close()
    }
}
