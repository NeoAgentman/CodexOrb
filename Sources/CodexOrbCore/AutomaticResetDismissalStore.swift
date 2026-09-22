import CryptoKit
import Foundation

/// A cancelled card stays manual-only, including after restart. Account deletion removes
/// these records along with the other reset operation state; credentials are never stored.
public struct AutomaticResetDismissalStore: Sendable {
    private struct Dismissal: Codable {
        let creditID: String
        let expiresAt: Date
    }
    private let pendingStore: PendingResetStore

    public init(root: URL = PendingResetStore().root) {
        pendingStore = PendingResetStore(root: root)
    }

    private func file(identity: String, creditID: String) throws -> URL {
        let hash = SHA256.hash(data: Data(creditID.utf8)).map { String(format: "%02x", $0) }.joined()
        return try pendingStore.directory(identity)
            .appendingPathComponent("DismissedAutomaticResets", isDirectory: true)
            .appendingPathComponent(hash + ".json")
    }

    public func contains(identity: String, creditID: String, now: Date = Date()) throws -> Bool {
        let url = try file(identity: identity, creditID: creditID)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let record = try JSONDecoder().decode(Dismissal.self, from: Data(contentsOf: url))
        guard record.creditID == creditID else { throw AppServerError.protocolError }
        return record.expiresAt > now
    }

    public func dismiss(identity: String, creditID: String, expiresAt: Date) throws {
        let url = try file(identity: identity, creditID: creditID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(Dismissal(creditID: creditID, expiresAt: expiresAt)).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
