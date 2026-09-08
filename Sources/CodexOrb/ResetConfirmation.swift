import AppKit
import CodexOrbCore

/// A compact, non-modal confirmation hosted by the capsule's popover.
@MainActor
final class ResetConfirmation: NSView {
    let question: NSTextField
    let accountLabel: NSTextField
    let confirmButton: NSButton
    let cancelButton: NSButton
    private var completion: ((Bool) -> Void)?

    init(account: String, recovering: Bool, completion: @escaping (Bool) -> Void) {
        self.completion = completion
        question = NSTextField(labelWithString: recovering ? L10n.text("恢复这个账号的重置操作？") : L10n.text("确认使用这个账号的重置卡？"))
        accountLabel = NSTextField(wrappingLabelWithString: account)
        confirmButton = NSButton(title: L10n.text("确认"), target: nil, action: nil)
        cancelButton = NSButton(title: L10n.text("取消"), target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 122))
        question.font = .systemFont(ofSize: 13, weight: .semibold)
        question.frame = NSRect(x: 16, y: 88, width: 288, height: 18)
        accountLabel.font = .systemFont(ofSize: 12)
        accountLabel.textColor = .secondaryLabelColor
        accountLabel.maximumNumberOfLines = 2
        accountLabel.frame = NSRect(x: 16, y: 48, width: 288, height: 34)
        for button in [cancelButton, confirmButton] {
            button.bezelStyle = .rounded
            button.target = self
            addSubview(button)
        }
        cancelButton.frame = NSRect(x: 144, y: 12, width: 76, height: 28)
        confirmButton.frame = NSRect(x: 228, y: 12, width: 76, height: 28)
        cancelButton.action = #selector(cancelClicked)
        confirmButton.action = #selector(confirmClicked)
        cancelButton.keyEquivalent = "\r"
        confirmButton.keyEquivalent = ""
        addSubview(question)
        addSubview(accountLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }
    override func cancelOperation(_ sender: Any?) { finish(false) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 || event.keyCode == 36 { finish(false) }
        else { super.keyDown(with: event) }
    }
    @objc private func confirmClicked() { finish(true) }
    @objc private func cancelClicked() { finish(false) }
    private func finish(_ confirmed: Bool) {
        let callback = completion
        completion = nil
        callback?(confirmed)
    }
}
