import CodexOrbCore
import Foundation

enum LocalizationChecks {
    static func run() throws {
        func expect(_ value: Bool, _ description: String) throws {
            if !value { throw NSError(domain: "LocalizationChecks", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: description]) }
        }
        let suite = "CodexOrb.localization-checks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try expect(AppLanguage.load(from: defaults) == .chinese, "Default language")
        defaults.set("en", forKey: AppLanguage.defaultsKey)
        try expect(AppLanguage.load(from: defaults) == .english, "Persisted English")
        defaults.set("unsupported", forKey: AppLanguage.defaultsKey)
        try expect(AppLanguage.load(from: defaults) == .chinese, "Unknown language fallback")
        let progress: L10n.Message = "已更新：\("1.0") → \("2.0")"
        try expect(progress.rendered(in: .english) == "Updated: 1.0 → 2.0", "English interpolation")
        try expect(progress.rendered(in: .chinese) == "已更新：1.0 → 2.0", "Stored progress retranslates")
        let error = CLIUpdateError.busy.message
        let failure: L10n.Message = "\(error)；继续使用 \("1.0")"
        try expect(failure.rendered(in: .english) == "Another update is in progress; continuing with 1.0",
                   "Nested errors retranslate")
        let arbitrary: L10n.Message = "模型：\("刷新{0}")"
        try expect(arbitrary.rendered(in: .english) == "Models: 刷新{0}", "User values remain verbatim")
        print("LocalizationChecks passed")
    }
}
