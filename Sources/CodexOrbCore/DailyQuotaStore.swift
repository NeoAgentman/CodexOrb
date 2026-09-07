import Foundation
import Darwin

public struct DailyQuotaUsage: Equatable, Sendable {
    public let consumedPercent: Double
    public let startedAt: Date
    public let isPartial: Bool
    public let isEstimated: Bool
}

/// A locked, atomically replaced journal shared by the app and midnight recorder.
public struct DailyQuotaStore: Sendable {
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexOrb", isDirectory: true)
    }
    private let directory: URL
    public init(directory: URL = Self.directory) { self.directory = directory }

    private struct Entry: Codable {
        var key: String
        var day: Date
        var startedAt: Date
        var lastAt: Date
        var lastUsed: Double
        var resetAt: Date?
        var consumed: Double
        var partial: Bool
        var estimated: Bool

        var usage: DailyQuotaUsage {
            DailyQuotaUsage(consumedPercent: consumed, startedAt: startedAt,
                            isPartial: partial, isEstimated: estimated)
        }
    }

    public func record(_ usage: CodexUsage, calendar: Calendar = .current) throws -> DailyQuotaUsage? {
        guard let window = [usage.weekly, usage.session].compactMap({ $0 })
            .first(where: { $0.windowMinutes == 10_080 }),
            let account = usage.accountKey else { return nil }
        let key = usage.provider + ":" + account
        let day = calendar.startOfDay(for: usage.updatedAt)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let descriptor = open(directory.appendingPathComponent("daily-quota.lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { flock(descriptor, LOCK_UN) }
        let url = directory.appendingPathComponent("daily-quota.json")
        var entries = FileManager.default.fileExists(atPath: url.path)
            ? try JSONDecoder().decode([Entry].self, from: Data(contentsOf: url)) : []
        if !entries.contains(where: { $0.key == key && $0.day == day }),
           let legacy = usage.legacyAccountKey,
           let index = entries.firstIndex(where: { $0.key == usage.provider + ":" + legacy && $0.day == day }) {
            entries[index].key = key
        }
        let current = min(100, max(0, window.usedPercent))
        let result: DailyQuotaUsage
        if let index = entries.firstIndex(where: { $0.key == key && $0.day == day }) {
            var entry = entries[index]
            guard usage.updatedAt > entry.lastAt else { return entry.usage }
            let resetChanged = entry.resetAt != nil && window.resetsAt != nil &&
                abs(window.resetsAt!.timeIntervalSince(entry.resetAt!)) > 60
            if resetChanged || current < entry.lastUsed {
                entry.consumed += current
                entry.estimated = true
            } else {
                entry.consumed += current - entry.lastUsed
            }
            entry.lastUsed = current
            entry.lastAt = usage.updatedAt
            entry.resetAt = window.resetsAt
            entries[index] = entry
            result = entry.usage
        } else {
            let entry = Entry(key: key, day: day, startedAt: usage.updatedAt, lastAt: usage.updatedAt,
                              lastUsed: current, resetAt: window.resetsAt, consumed: 0,
                              partial: usage.updatedAt.timeIntervalSince(day) > 300, estimated: false)
            entries.append(entry)
            result = entry.usage
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entries).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return result
    }
}
