import CryptoKit
import Foundation

public struct CodexAccount: Equatable, Sendable {
    public let home: String
    public let email: String
    public let workspace: String
    public let identityKey: String
    public let accountID: String?

    public var label: String {
        "\(email) · \(workspace)"
    }
}

/// Only public identity claims are exposed; credentials remain in their original Codex homes.
public struct CodexAccountStore: Sendable {
    public let root: URL
    public let nativeHome: URL

    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Support/CodexOrb/Accounts"),
                nativeHome: URL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"]
                    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path)) {
        self.root = root
        self.nativeHome = nativeHome
    }

    public func accounts(additionalHomes: [String] = []) -> [CodexAccount] {
        let owned = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let homes = [nativeHome] + owned.sorted { $0.path < $1.path } + additionalHomes.map { URL(fileURLWithPath: $0) }
        var seen = Set<String>()
        return homes.compactMap { home in
            let path = home.standardizedFileURL.resolvingSymlinksInPath().path
            guard seen.insert(path).inserted else { return nil }
            return try? Self.read(home: URL(fileURLWithPath: path))
        }
    }

    /// Returns only accounts created inside CodexOrb's private account root.
    /// Native and externally configured Codex homes are intentionally excluded.
    public func managedAccounts() -> [CodexAccount] {
        let homes = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return homes.sorted { $0.path < $1.path }.compactMap { self.managedAccount(at: $0) }
    }

    /// Reads an account only when its resolved home is a direct child of
    /// CodexOrb's private account root.
    public func managedAccount(at home: URL) -> CodexAccount? {
        let resolved = URL(fileURLWithPath: home.path).standardizedFileURL.resolvingSymlinksInPath()
        guard self.isManagedHome(resolved) else { return nil }
        return try? Self.read(home: resolved)
    }

    public static func read(home: URL) throws -> CodexAccount {
        let data = try Data(contentsOf: home.appendingPathComponent("auth.json"))
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String, !access.isEmpty,
              let jwt = tokens["id_token"] as? String,
              let claims = Self.claims(jwt),
              let email = claims["email"] as? String, !email.isEmpty
        else { throw CodexAccountError.invalidAccount }
        let auth = claims["https://api.openai.com/auth"] as? [String: Any] ?? [:]
        let accountID = [tokens["account_id"] as? String, auth["chatgpt_account_id"] as? String]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        let plan = auth["chatgpt_plan_type"] as? String ?? "Codex"
        let key = SHA256.hash(data: Data((email.lowercased() + ":" + (accountID ?? "")).utf8))
            .map { String(format: "%02x", $0) }.joined()
        return CodexAccount(home: home.path, email: email, workspace: plan, identityKey: key, accountID: accountID)
    }

    private static func claims(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    public func createLoginHome() throws -> URL {
        let home = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        return home
    }

    /// Removes the credentials and local account data represented by an account.
    ///
    /// Only homes created by CodexOrb are eligible. Their whole private account
    /// directory is removed; native and externally configured homes are rejected.
    public func delete(
        account: CodexAccount,
        pendingResetStore: PendingResetStore = PendingResetStore()) throws
    {
        let home = URL(fileURLWithPath: account.home).standardizedFileURL
        guard self.isManagedHome(home) else {
            throw CodexAccountError.notManaged
        }
        let current = try Self.read(home: home)
        guard current.identityKey == account.identityKey else {
            throw CodexAccountError.accountChanged
        }

        // Do this first so a busy or locked reset operation prevents credential
        // deletion and can still be recovered by the caller.
        try pendingResetStore.deleteAccountData(account.identityKey)

        try FileManager.default.trashItem(at: home, resultingItemURL: nil)
    }

    private func isManagedHome(_ home: URL) -> Bool {
        let normalizedHome = home.resolvingSymlinksInPath().path
        let normalizedRoot = self.root.standardizedFileURL.resolvingSymlinksInPath().path
        return home.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path == normalizedRoot
            && normalizedHome != normalizedRoot
    }

    public static func configuredHomes() -> [String] {
        let fm = FileManager.default
        let userHome = fm.homeDirectoryForCurrentUser
        let env = ProcessInfo.processInfo.environment
        let candidates: [String?] = [env["CODEXBAR_CONFIG"],
                          (env["XDG_CONFIG_HOME"] ?? userHome.appendingPathComponent(".config").path) + "/codexbar/config.json",
                          userHome.appendingPathComponent(".codexbar/config.json").path]
        guard let path = candidates.compactMap({ $0 }).first(where: { fm.fileExists(atPath: $0) }),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let providers = json["providers"] as? [[String: Any]],
              let codex = providers.first(where: { $0["id"] as? String == "codex" }) else { return [] }
        return (codex["codexProfileHomePaths"] as? [String] ?? []).compactMap {
            if $0.hasPrefix("~/") { return userHome.appendingPathComponent(String($0.dropFirst(2))).path }
            return $0.hasPrefix("/") ? $0 : nil
        }
    }
}

public enum CodexAccountError: LocalizedError {
    case invalidAccount, accountChanged, noManagedAccount, notManaged, missingCLI, loginFailed
    public var errorDescription: String? {
        switch self {
        case .invalidAccount: L10n.text("账号登录已失效或尚未完成，请重新登录。")
        case .accountChanged: L10n.text("账号身份已变化，请重新选择账号。")
        case .noManagedAccount: L10n.text("暂无 CodexOrb 管理的账号。")
        case .notManaged: L10n.text("只能删除 CodexOrb 管理的账号。")
        case .missingCLI: L10n.text("未找到 Codex CLI，请先安装 Codex。")
        case .loginFailed: L10n.text("登录未完成，请重试并在浏览器中完成授权。")
        }
    }
}
