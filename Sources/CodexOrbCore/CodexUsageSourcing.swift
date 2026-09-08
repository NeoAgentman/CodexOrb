import Foundation

public protocol CodexUsageSourcing: Sendable {
    func fetch() async throws -> CodexUsage
}
