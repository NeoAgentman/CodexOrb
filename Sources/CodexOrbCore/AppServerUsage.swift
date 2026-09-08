import Foundation

public enum AppServerUsageParser {
    public static func parse(_ data: Data, expectedAccountID: String? = nil, now: Date = Date()) throws -> CodexUsage {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["rateLimits"] is [String: Any] else { throw AppServerError.protocolError }
        if let actual = object["accountId"] as? String, let expectedAccountID, actual != expectedAccountID {
            throw AppServerError.accountChanged
        }
        let buckets = object["rateLimitsByLimitId"] as? [String: [String: Any]]
        let legacy = object["rateLimits"] as? [String: Any]
        let bucket: [String: Any]?
        if let buckets, !buckets.isEmpty {
            bucket = buckets["codex"] ?? buckets.values.first { $0["limitId"] as? String == "codex" }
        } else {
            let id = legacy?["limitId"] as? String
            bucket = id == nil || id == "codex" ? legacy : nil
        }
        let windows = [bucket?["primary"], bucket?["secondary"]].compactMap { $0 as? [String: Any] }
        func window(_ minutes: Int) -> CodexQuotaWindow? {
            guard let value = windows.first(where: { $0["windowDurationMins"] as? Int == minutes }),
                  let used = value["usedPercent"] as? Double, used.isFinite else { return nil }
            return CodexQuotaWindow(usedPercent: used, windowMinutes: minutes,
                                    resetsAt: (value["resetsAt"] as? Double).map(Date.init(timeIntervalSince1970:)), resetDescription: nil)
        }
        var resets: CodexResetCredits?
        if let summary = object["rateLimitResetCredits"] as? [String: Any], let count = summary["availableCount"] as? Int {
            let cards = (summary["credits"] as? [[String: Any]])?.compactMap { value -> CodexResetCredits.Credit? in
                guard let id = value["id"] as? String, !id.isEmpty, let status = value["status"] as? String else { return nil }
                return .init(id: id, status: status, resetType: value["resetType"] as? String,
                             expiresAt: (value["expiresAt"] as? Double).map(Date.init(timeIntervalSince1970:)))
            }
            resets = CodexResetCredits(availableCount: count, credits: cards)
        }
        return CodexUsage(session: window(300), weekly: window(10080), resetCredits: resets, updatedAt: now)
    }
}

public enum ResetOutcome: String, Codable, Sendable {
    case reset, alreadyRedeemed, nothingToReset, noCredit
}

public struct PendingReset: Codable, Equatable, Sendable {
    public let identityKey: String
    public let creditID: String
    public let idempotencyKey: String
    public let createdAt: Date
    public var outcome: ResetOutcome?

    public init(identityKey: String, creditID: String, idempotencyKey: String = UUID().uuidString, createdAt: Date = Date(), outcome: ResetOutcome? = nil) {
        self.identityKey = identityKey; self.creditID = creditID; self.idempotencyKey = idempotencyKey
        self.createdAt = createdAt; self.outcome = outcome
    }
}

public enum PendingResetState: Equatable, Sendable {
    case none
    case pending(PendingReset)
    case unreadable
}

/// A single pending operation per account, never a credential store.
public struct PendingResetStore: Sendable {
    public let root: URL
    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CodexOrb/ResetOperations")) { self.root = root }
    public func directory(_ identity: String) throws -> URL {
        guard identity.count == 64, identity.allSatisfy({ $0.isHexDigit }) else { throw AppServerError.accountChanged }
        return root.appendingPathComponent(identity)
    }
    public func read(_ identity: String) throws -> PendingReset? {
        let url = try directory(identity).appendingPathComponent("pending.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let pending = try JSONDecoder().decode(PendingReset.self, from: Data(contentsOf: url))
        guard pending.identityKey == identity, !pending.creditID.isEmpty, UUID(uuidString: pending.idempotencyKey) != nil else { throw AppServerError.protocolError }
        return pending
    }
    public func state(_ identity: String) -> PendingResetState {
        do {
            return try read(identity).map(PendingResetState.pending) ?? .none
        } catch {
            return .unreadable
        }
    }
    public func save(_ pending: PendingReset) throws {
        let dir = try directory(pending.identityKey)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = dir.appendingPathComponent("pending.json")
        try JSONEncoder().encode(pending).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func clear(_ identity: String) throws {
        let url = try directory(identity).appendingPathComponent("pending.json")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    /// Removes all local operation state for an account after explicit account deletion.
    public func deleteAccountData(_ identity: String) throws {
        let dir = try directory(identity)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: dir.path) {
            let lock = try CLIUpdateLock(directory: dir)
            defer { withExtendedLifetime(lock) {} }
            try fileManager.trashItem(at: dir, resultingItemURL: nil)
        }

        let quarantine = root.appendingPathComponent("Quarantine", isDirectory: true)
        guard fileManager.fileExists(atPath: quarantine.path) else { return }
        let prefix = identity + "-"
        let related = try fileManager.contentsOfDirectory(at: quarantine, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
        for file in related {
            try fileManager.trashItem(at: file, resultingItemURL: nil)
        }
    }

    /// Moves an unreadable record out of the active path without destroying it.
    /// The caller must get explicit user confirmation before invoking this method.
    public func quarantineUnreadable(_ identity: String) throws -> URL {
        let dir = try directory(identity)
        let lock = try CLIUpdateLock(directory: dir)
        defer { withExtendedLifetime(lock) {} }
        let source = dir.appendingPathComponent("pending.json")
        guard FileManager.default.fileExists(atPath: source.path) else { throw AppServerError.protocolError }
        do {
            _ = try read(identity)
            throw AppServerError.busy
        } catch AppServerError.busy {
            throw AppServerError.busy
        } catch {
            let quarantine = root.appendingPathComponent("Quarantine", isDirectory: true)
            try FileManager.default.createDirectory(
                at: quarantine,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: quarantine.path)
            let destination = quarantine.appendingPathComponent("\(identity)-\(UUID().uuidString).json")
            try FileManager.default.moveItem(at: source, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            return destination
        }
    }
}

public struct ResetResult: Sendable {
    public let outcome: ResetOutcome
    public let usage: CodexUsage?
}

/// Serializes quota reads and mutations by account, including across CodexOrb processes.
public actor CodexAccountService {
    public static let shared = CodexAccountService()
    private var active = Set<String>()
    private let pendingStore: PendingResetStore
    private let executable: URL?
    private let timeout: TimeInterval

    public init(pendingStore: PendingResetStore = PendingResetStore(), executable: URL? = nil, timeout: TimeInterval = 20) {
        self.pendingStore = pendingStore; self.executable = executable; self.timeout = timeout
    }
    public func pending(account: CodexAccount) throws -> PendingReset? { try pendingStore.read(account.identityKey) }

    public func fetch(account: CodexAccount) async throws -> CodexUsage {
        try await run(account: account) { connection in try Self.read(connection, account: account) }
    }

    public func consume(account: CodexAccount, creditID: String) async throws -> ResetResult {
        let store = pendingStore
        return try await run(account: account) { connection in
            var pending = try store.read(account.identityKey)
            // Verify the server account even when recovering an uncertain request.
            let preflight = pending?.outcome == nil ? try Self.read(connection, account: account) : nil
            if pending == nil {
                let usage = preflight!
                guard usage.resetCredits?.availableCount ?? 0 > 0,
                      usage.resetCredits?.availableCards.contains(where: { $0.id == creditID && $0.isRedeemable() }) == true else {
                    throw AppServerError.cardUnavailable
                }
                pending = PendingReset(identityKey: account.identityKey, creditID: creditID)
                // Persist before sending; even a crash or lost response must reuse this key.
                try store.save(pending!)
            }
            var operation = pending!
            // A recovered operation must never silently switch to a newly clicked card.
            guard operation.creditID == creditID else { throw AppServerError.busy }
            try Self.verify(account)
            if operation.outcome == nil {
                let response = try connection.request("account/rateLimitResetCredit/consume", params: [
                    "creditId": operation.creditID, "idempotencyKey": operation.idempotencyKey,
                ])
                guard let value = response["outcome"] as? String, let outcome = ResetOutcome(rawValue: value) else { throw AppServerError.protocolError }
                operation.outcome = outcome
                // Failure to persist must not turn a known success into an unknown result.
                try? store.save(operation)
            }
            let outcome = operation.outcome!
            do {
                let usage = try Self.read(connection, account: account)
                try store.clear(account.identityKey)
                return ResetResult(outcome: outcome, usage: usage)
            } catch {
                return ResetResult(outcome: outcome, usage: nil)
            }
        }
    }

    private func run<T: Sendable>(account: CodexAccount, operation: @escaping @Sendable (AppServerConnection) throws -> T) async throws -> T {
        guard active.insert(account.identityKey).inserted else { throw AppServerError.busy }
        defer { active.remove(account.identityKey) }
        let lockDirectory = try pendingStore.directory(account.identityKey)
        try FileManager.default.createDirectory(at: lockDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: lockDirectory.path)
        let lock = try CLIUpdateLock(directory: lockDirectory)
        defer { withExtendedLifetime(lock) {} }
        let binary: URL
        if let executable { binary = executable } else { binary = try await CodexRuntime.shared.resolve() }
        try Task.checkCancellation()
        let cancellation = ServerCancellation()
        let timeout = timeout
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                try cancellation.check()
                try Self.verify(account)
                let connection = try AppServerConnection(executable: binary, account: account, cancellation: cancellation, timeout: timeout)
                defer { connection.close() }
                try connection.start(account: account)
                return try operation(connection)
            }.value
        } onCancel: { cancellation.cancel() }
    }

    private static func verify(_ account: CodexAccount) throws {
        guard try CodexAccountStore.read(home: URL(fileURLWithPath: account.home)).identityKey == account.identityKey else {
            throw AppServerError.accountChanged
        }
    }
    private static func read(_ connection: AppServerConnection, account: CodexAccount) throws -> CodexUsage {
        try verify(account)
        let object = try connection.request("account/rateLimits/read")
        let usage = try AppServerUsageParser.parse(JSONSerialization.data(withJSONObject: object), expectedAccountID: account.accountID)
        try verify(account)
        return usage
    }
}

public struct CodexAppServerUsageSource: CodexUsageSourcing {
    private let accountHome: String?
    private let service: CodexAccountService
    public init(accountHome: String? = nil, service: CodexAccountService = .shared) {
        self.accountHome = accountHome; self.service = service
    }
    public func fetch() async throws -> CodexUsage {
        guard let accountHome else { throw CodexAccountError.noManagedAccount }
        guard let account = CodexAccountStore().managedAccount(at: URL(fileURLWithPath: accountHome)) else {
            throw CodexAccountError.notManaged
        }
        return try await service.fetch(account: account)
    }
}
