import CryptoKit
import Foundation

public struct CodexAccount: Equatable, Sendable {
    public let home: String
    public let email: String
    public let workspace: String
    public let identityKey: String
    public let accountID: String

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
        let accountID = tokens["account_id"] as? String ?? auth["chatgpt_account_id"] as? String ?? ""
        let plan = auth["chatgpt_plan_type"] as? String ?? "Codex"
        let key = SHA256.hash(data: Data((email.lowercased() + ":" + accountID).utf8))
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
    case invalidAccount, missingCLI, loginFailed
    public var errorDescription: String? {
        switch self {
        case .invalidAccount: L10n.text("账号登录已失效或尚未完成，请重新登录。")
        case .missingCLI: L10n.text("未找到 Codex CLI，请先安装 Codex。")
        case .loginFailed: L10n.text("登录未完成，请重试并在浏览器中完成授权。")
        }
    }
}
