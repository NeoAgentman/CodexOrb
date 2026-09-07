import CryptoKit
import Darwin
import Foundation

public enum CLITool: String, CaseIterable, Codable, Sendable {
    case codexbar, opentoken

    public var title: String { self == .codexbar ? "CodexBar" : "OpenToken" }
}

public struct CLIInstallation: Codable, Equatable, Sendable {
    public let version: String
    public let generation: String
    public let sha256: String
}

/// Each tool has an independent atomic pointer to an immutable, validated installation.
/// Existing generations remain available to in-flight GUI and recorder processes.
public struct CLIInstallationStore: Sendable {
    public let root: URL
    public let bundledDirectory: URL

    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/CodexOrb/CLI", isDirectory: true),
        bundledDirectory: URL = BundledCLITools.directory)
    {
        self.root = root
        self.bundledDirectory = bundledDirectory
    }

    public func bundledVersion(for tool: CLITool) -> String {
        guard let data = try? Data(contentsOf: self.bundledDirectory.appendingPathComponent("versions.json")),
              let versions = try? JSONDecoder().decode([String: String].self, from: data)
        else { return "unknown" }
        return versions[tool.rawValue] ?? "unknown"
    }

    public func installation(for tool: CLITool) -> CLIInstallation? {
        guard let data = try? Data(contentsOf: self.pointer(for: tool)),
              let record = try? JSONDecoder().decode(CLIInstallation.self, from: data),
              UUID(uuidString: record.generation) != nil,
              CLIVersion(record.version) != nil else { return nil }
        let executable = self.directory(for: record, tool: tool).appendingPathComponent(tool.rawValue)
        guard FileManager.default.isExecutableFile(atPath: executable.path),
              (try? Self.digest(of: executable)) == record.sha256 else { return nil }
        return record
    }

    public func activeDirectory(for tool: CLITool) -> URL {
        guard let record = self.installation(for: tool) else { return self.bundledDirectory }
        return self.directory(for: record, tool: tool)
    }

    public func activeVersion(for tool: CLITool) -> String {
        self.installation(for: tool)?.version ?? self.bundledVersion(for: tool)
    }

    public func toolDirectory(for tool: CLITool) -> URL {
        self.root.appendingPathComponent(tool.rawValue, isDirectory: true)
    }

    public func directory(for record: CLIInstallation, tool: CLITool) -> URL {
        self.toolDirectory(for: tool).appendingPathComponent("releases/\(record.generation)", isDirectory: true)
    }

    private func pointer(for tool: CLITool) -> URL {
        self.toolDirectory(for: tool).appendingPathComponent("current.json")
    }

    /// Called only after validation, while holding this tool's update lock.
    public func activate(_ stagedDirectory: URL, version: String, for tool: CLITool) throws {
        guard CLIVersion(version) != nil else { throw CLIUpdateError.invalidVersion }
        let record = CLIInstallation(version: version, generation: UUID().uuidString,
                                     sha256: try Self.digest(of: stagedDirectory.appendingPathComponent(tool.rawValue)))
        let destination = self.directory(for: record, tool: tool)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: stagedDirectory, to: destination)
        // If the write fails (or the app exits before it), the old pointer remains intact.
        try JSONEncoder().encode(record).write(to: self.pointer(for: tool), options: .atomic)
    }

    public static func digest(of url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe))
            .map { String(format: "%02x", $0) }.joined()
    }
}

public struct CLIVersion: Comparable, Sendable {
    private let parts: [Int]

    public init?(_ rawValue: String) {
        let value = rawValue.hasPrefix("v") ? String(rawValue.dropFirst()) : rawValue
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              parts.allSatisfy({ Int($0) != nil }) else { return nil }
        self.parts = parts.map { Int($0)! }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.parts.lexicographicallyPrecedes(rhs.parts)
    }
}

final class CLIUpdateLock: @unchecked Sendable {
    private let descriptor: Int32

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.descriptor = open(directory.appendingPathComponent("update.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard self.descriptor >= 0 else { throw CLIUpdateError.storage }
        guard flock(self.descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(self.descriptor)
            throw CLIUpdateError.busy
        }
    }

    deinit {
        flock(self.descriptor, LOCK_UN)
        close(self.descriptor)
    }
}
