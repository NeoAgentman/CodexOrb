import Foundation

public enum CLIUpdateError: LocalizedError, Sendable {
    case busy, storage, invalidVersion, channelUnavailable, checksum, archive, validation, timeout, outputTooLarge

    public var errorDescription: String? { self.message.rendered() }

    public var message: L10n.Message {
        switch self {
        case .busy: "另一个更新正在进行"
        case .storage: "无法写入更新目录"
        case .invalidVersion: "更新版本信息无效"
        case .channelUnavailable: "无法确认官方更新渠道，请稍后重试"
        case .checksum: "下载文件校验失败"
        case .archive: "更新包内容不完整或不安全"
        case .validation: "新版运行或数据校验失败"
        case .timeout: "更新操作超时"
        case .outputTooLarge: "更新命令输出异常"
        }
    }
}

public struct CLIUpdateResult: Sendable {
    public enum Outcome: Sendable { case updated, unchanged, failed }
    public let outcome: Outcome
    public let version: String
    public let localizedMessage: L10n.Message
    public var message: String { localizedMessage.rendered() }

    public init(outcome: Outcome, version: String, message: L10n.Message) {
        self.outcome = outcome
        self.version = version
        self.localizedMessage = message
    }
}

public struct CodexBarRelease: Decodable, Sendable {
    public struct Asset: Decodable, Sendable {
        public let name: String
        public let browser_download_url: URL
        public let digest: String?
    }
    public let tag_name: String
    public let draft: Bool
    public let prerelease: Bool
    public let assets: [Asset]

    public func candidate(architecture: String) throws -> Asset {
        guard !self.draft, !self.prerelease, CLIVersion(self.tag_name) != nil,
              ["arm64", "x86_64"].contains(architecture),
              let asset = self.assets.first(where: {
                  $0.name == "CodexBarCLI-\(self.tag_name)-macos-\(architecture).tar.gz"
              }),
              asset.browser_download_url.scheme == "https",
              asset.browser_download_url.host == "github.com",
              asset.browser_download_url.path == "/steipete/CodexBar/releases/download/\(self.tag_name)/\(asset.name)",
              let digest = asset.digest, digest.hasPrefix("sha256:"),
              digest.dropFirst(7).count == 64,
              digest.dropFirst(7).allSatisfy({ $0.isHexDigit })
        else { throw CLIUpdateError.channelUnavailable }
        return asset
    }
}

public struct CLIUpdater: Sendable {
    public typealias Progress = @Sendable (L10n.Message) async -> Void
    public typealias Prepare = @Sendable (CLITool, String, URL, URL, Progress) async throws -> String?
    public typealias Validate = @Sendable (CLITool, URL, String, String) async throws -> Void

    public let store: CLIInstallationStore
    private let prepare: Prepare?
    private let validate: Validate?

    public init(store: CLIInstallationStore = CLIInstallationStore(),
                prepare: Prepare? = nil,
                validate: Validate? = nil)
    {
        self.store = store
        self.prepare = prepare
        self.validate = validate
    }

    public func update(_ tool: CLITool, accountHome: String = CodexAccountStore().nativeHome.path,
                       progress: @escaping Progress = { _ in }) async -> CLIUpdateResult
    {
        do {
            let lock = try CLIUpdateLock(directory: self.store.toolDirectory(for: tool))
            defer { withExtendedLifetime(lock) {} }
            let current = self.store.activeVersion(for: tool)
            guard let currentVersion = CLIVersion(current) else { throw CLIUpdateError.invalidVersion }
            let work = self.store.toolDirectory(for: tool).appendingPathComponent("staging-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.trashItem(at: work, resultingItemURL: nil) }
            await progress("检查更新…")
            // Direct calls avoid Swift 6.2's async default-function-reference thunk, which can
            // unbalance task allocations when the OpenToken replacement path suspends.
            let candidateVersion: String?
            if let prepare = self.prepare {
                candidateVersion = try await prepare(tool, current, self.store.activeDirectory(for: tool), work, progress)
            } else {
                candidateVersion = try await Self.prepareCandidate(tool, current: current,
                    currentDirectory: self.store.activeDirectory(for: tool), work: work, progress: progress)
            }
            guard let version = candidateVersion else {
                return CLIUpdateResult(outcome: .unchanged, version: current,
                                       message: "\(current) · 当前渠道暂无可用更新")
            }
            guard let nextVersion = CLIVersion(version), nextVersion > currentVersion else {
                throw CLIUpdateError.invalidVersion
            }
            let ready = work.appendingPathComponent("ready")
            await progress("验证 \(version)…")
            if let validate = self.validate {
                try await validate(tool, ready, version, accountHome)
            } else {
                try await Self.validateCandidate(tool, directory: ready, version: version, accountHome: accountHome)
            }
            await progress("启用 \(version)…")
            try self.store.activate(ready, version: version, for: tool)
            return CLIUpdateResult(outcome: .updated, version: version, message: "已更新：\(current) → \(version)")
        } catch {
            let version = self.store.activeVersion(for: tool)
            // Upstream stderr may contain account URLs. Only expose our own bounded descriptions.
            let reason: L10n.Message = (error as? CLIUpdateError)?.message ?? "网络或文件操作失败，请重试"
            return CLIUpdateResult(outcome: .failed, version: version, message: "\(reason)；继续使用 \(version)")
        }
    }

    public static func prepareCandidate(_ tool: CLITool, current: String, currentDirectory: URL,
                                        work: URL, progress: Progress) async throws -> String?
    {
        switch tool {
        case .codexbar:
            return try await self.prepareCodexBar(current: current, work: work, progress: progress)
        case .opentoken:
            return try await self.prepareOpenToken(current: current, currentDirectory: currentDirectory,
                                                   work: work, progress: progress)
        }
    }

    private static func prepareCodexBar(current: String, work: URL, progress: Progress) async throws -> String? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/steipete/CodexBar/releases/latest")!)
        request.setValue("CodexOrb-CLI-Updater", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 2_097_152 else {
            throw CLIUpdateError.channelUnavailable
        }
        let release = try JSONDecoder().decode(CodexBarRelease.self, from: data)
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let asset = try release.candidate(architecture: architecture)
        guard let latest = CLIVersion(release.tag_name), let installed = CLIVersion(current) else {
            throw CLIUpdateError.invalidVersion
        }
        guard latest > installed else { return nil }
        let version = String(release.tag_name.dropFirst(release.tag_name.hasPrefix("v") ? 1 : 0))
        await progress("下载 \(version)…")
        let (download, downloadResponse) = try await session.download(from: asset.browser_download_url)
        defer { try? FileManager.default.trashItem(at: download, resultingItemURL: nil) }
        guard (downloadResponse as? HTTPURLResponse)?.statusCode == 200,
              downloadResponse.url?.scheme == "https",
              let size = try FileManager.default.attributesOfItem(atPath: download.path)[.size] as? NSNumber,
              size.intValue > 0, size.intValue <= 157_286_400 else { throw CLIUpdateError.channelUnavailable }
        guard try CLIInstallationStore.digest(of: download) == String(asset.digest!.dropFirst(7)).lowercased() else {
            throw CLIUpdateError.checksum
        }
        let archive = work.appendingPathComponent("download.tar.gz")
        try FileManager.default.moveItem(at: download, to: archive)
        await progress("解压并检查资源…")
        let listing = try await CLIUpdateProcess.run(URL(fileURLWithPath: "/usr/bin/tar"), arguments: ["-tzf", archive.path])
        guard listing.status == 0, let text = String(data: listing.stdout, encoding: .utf8),
              self.safeArchivePaths(text) else { throw CLIUpdateError.archive }
        let extracted = work.appendingPathComponent("extracted")
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        let unpack = try await CLIUpdateProcess.run(URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-xzf", archive.path, "--no-same-owner", "-C", extracted.path], writableDirectory: extracted)
        guard unpack.status == 0 else { throw CLIUpdateError.archive }
        let binary = extracted.appendingPathComponent("CodexBarCLI")
        let resources = extracted.appendingPathComponent("CodexBar_CodexBarCore.bundle")
        guard FileManager.default.isExecutableFile(atPath: binary.path),
              FileManager.default.fileExists(atPath: resources.path),
              try String(contentsOf: extracted.appendingPathComponent("VERSION"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines) == version else { throw CLIUpdateError.archive }
        // Resolve every link before copying: the archive may include an internal codexbar alias.
        try self.validateExtractedPaths(extracted)
        let ready = work.appendingPathComponent("ready")
        try FileManager.default.createDirectory(at: ready, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: binary, to: ready.appendingPathComponent("codexbar"))
        try FileManager.default.copyItem(at: resources, to: ready.appendingPathComponent(resources.lastPathComponent))
        try FileManager.default.copyItem(at: extracted.appendingPathComponent("VERSION"), to: ready.appendingPathComponent("VERSION"))
        let watchdog = extracted.appendingPathComponent("CodexBarClaudeWatchdog")
        if FileManager.default.fileExists(atPath: watchdog.path) {
            try FileManager.default.copyItem(at: watchdog, to: ready.appendingPathComponent(watchdog.lastPathComponent))
        }
        return version
    }

    public static func safeArchivePaths(_ listing: String) -> Bool {
        let paths = listing.split(separator: "\n")
        return !paths.isEmpty && paths.allSatisfy {
            !$0.hasPrefix("/") && !$0.split(separator: "/").contains("..") && !$0.contains("\\")
        }
    }

    private static func validateExtractedPaths(_ directory: URL) throws {
        let root = directory.resolvingSymlinksInPath().path + "/"
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey])
        else { throw CLIUpdateError.archive }
        for case let url as URL in enumerator {
            guard url.resolvingSymlinksInPath().path.hasPrefix(root) else { throw CLIUpdateError.archive }
        }
    }

    private static func prepareOpenToken(current: String, currentDirectory: URL, work: URL,
                                         progress: Progress) async throws -> String?
    {
        let binary = work.appendingPathComponent("opentoken")
        try FileManager.default.copyItem(at: currentDirectory.appendingPathComponent("opentoken"), to: binary)
        let before = try CLIInstallationStore.digest(of: binary)
        let temp = work.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        var environment = ProcessInfo.processInfo.environment
        environment["TMPDIR"] = temp.path + "/"
        await progress("检查并更新临时副本…")
        let output = try await CLIUpdateProcess.run(binary, arguments: ["self-update"], timeout: 120,
                                                   writableDirectory: work, environment: environment)
        let log = String(decoding: output.stdout + output.stderr, as: UTF8.self)
        guard output.status == 0, !log.contains("实时配置拉取失败"), !log.contains("结果可能过期") else {
            throw CLIUpdateError.channelUnavailable
        }
        let version = try await self.readVersion(binary, tool: .opentoken)
        if version == current {
            guard try CLIInstallationStore.digest(of: binary) == before else { throw CLIUpdateError.invalidVersion }
            return nil
        }
        let ready = work.appendingPathComponent("ready")
        try FileManager.default.createDirectory(at: ready, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: binary, to: ready.appendingPathComponent("opentoken"))
        return version
    }

    public static func readVersion(_ binary: URL, tool: CLITool) async throws -> String {
        let output = try await CLIUpdateProcess.run(binary, arguments: ["--version"], timeout: 10)
        let value = String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = value.split(separator: " ")
        guard output.status == 0, parts.count == 2, parts[0].lowercased() == tool.rawValue,
              CLIVersion(String(parts[1])) != nil else { throw CLIUpdateError.invalidVersion }
        return String(parts[1])
    }

    public static func validateCandidate(_ tool: CLITool, directory: URL, version: String, accountHome: String) async throws {
        let binary = directory.appendingPathComponent(tool.rawValue)
        let signature = try await CLIUpdateProcess.run(URL(fileURLWithPath: "/usr/bin/codesign"),
                                                       arguments: ["--verify", "--strict", binary.path])
        guard signature.status == 0, try await self.readVersion(binary, tool: tool) == version else {
            throw CLIUpdateError.validation
        }
        let arguments: [String]
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.string(from: Date())
        switch tool {
        case .codexbar:
            arguments = ["usage", "--provider", "codex", "--source", "oauth", "--format", "json", "--json-only"]
        case .opentoken:
            arguments = ["preview", "--since", date, "--json"]
        }
        var environment = ProcessInfo.processInfo.environment
        if tool == .codexbar { environment["CODEX_HOME"] = accountHome }
        let output = try await CLIUpdateProcess.run(binary, arguments: arguments, timeout: 30, environment: environment)
        guard output.status == 0 else { throw CLIUpdateError.validation }
        do {
            switch tool {
            case .codexbar: _ = try CodexUsageParser.parse(output.stdout)
            case .opentoken: _ = try OpenTokenUsageParser.parse(output.stdout, date: date)
            }
        } catch { throw CLIUpdateError.validation }
    }
}
