import AppKit
import CodexOrbCore

@MainActor
enum ResetConfirmation {
    static func makeAlert(accountLabel: String, detail: String, recovering: Bool) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = recovering ? L10n.text("恢复上次重置操作？") : L10n.text("使用这张重置卡？")
        alert.informativeText = accountLabel + "\n" + detail
        alert.addButton(withTitle: recovering ? L10n.text("恢复操作") : L10n.text("使用 1 张"))
        alert.addButton(withTitle: L10n.text("取消"))
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        return alert
    }

    static func confirm(accountLabel: String, detail: String, recovering: Bool,
                        present: @MainActor (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() }) -> Bool {
        let alert = makeAlert(accountLabel: accountLabel, detail: detail, recovering: recovering)
        return present(alert) == .alertFirstButtonReturn
    }
}
