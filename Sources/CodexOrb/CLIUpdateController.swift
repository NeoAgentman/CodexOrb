import CodexOrbCore
import Foundation

/// Owned independently of the settings window so closing/reopening it preserves progress.
@MainActor
final class CLIUpdateController {
    static let shared = CLIUpdateController()
    private(set) var messages: [CLITool: L10n.Message] = [:]
    private(set) var failed: Set<CLITool> = []
    private(set) var isRunning = false
    var onChange: (() -> Void)?
    var onFinished: (() -> Void)?

    private init() {
        let store = CLIInstallationStore()
        for tool in CLITool.allCases { self.messages[tool] = "当前版本 \(store.activeVersion(for: tool))" }
    }

    func start(accountHome: String?) {
        guard !self.isRunning else { return }
        self.isRunning = true
        self.failed = []
        for tool in CLITool.allCases { self.messages[tool] = "检查更新…" }
        self.onChange?()
        let updater = CLIUpdater()
        Task {
            await withTaskGroup(of: (CLITool, CLIUpdateResult).self) { group in
                for tool in CLITool.allCases {
                    group.addTask {
                        let result = await updater.update(tool, accountHome: accountHome) { phase in
                            await MainActor.run {
                                self.messages[tool] = phase
                                self.onChange?()
                            }
                        }
                        return (tool, result)
                    }
                }
                for await (tool, result) in group {
                    self.messages[tool] = result.localizedMessage
                    if case .failed = result.outcome { self.failed.insert(tool) }
                    self.onChange?()
                }
            }
            self.isRunning = false
            self.onChange?()
            self.onFinished?()
        }
    }
}
