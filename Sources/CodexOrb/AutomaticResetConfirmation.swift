import AppKit
import CodexOrbCore

@MainActor
final class AutomaticResetConfirmation: NSWindowController, NSWindowDelegate {
    enum Decision { case use, cancel, interrupted }
    struct Item {
        let account: String
        let expiresAt: Date
    }
    private let accountList = NSScrollView()
    private let countdownLabel = NSTextField(labelWithString: "")
    private let useButton = NSButton()
    private let cancelButton = NSButton()
    private var timer: Timer?
    private var deadline: TimeInterval = 0
    private var completion: ((Decision) -> Void)?
    private var confirmationID: UUID?

    init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 196),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = AutomaticResetContentView(frame: NSRect(x: 0, y: 0, width: 400, height: 196))
        super.init(window: panel)
        panel.delegate = self
        accountList.drawsBackground = false
        accountList.hasVerticalScroller = true
        accountList.autohidesScrollers = true
        countdownLabel.frame = NSRect(x: 20, y: 64, width: 360, height: 20)
        countdownLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        cancelButton.frame = NSRect(x: 148, y: 16, width: 112, height: 32)
        useButton.frame = NSRect(x: 268, y: 16, width: 112, height: 32)
        for button in [cancelButton, useButton] {
            button.bezelStyle = .rounded
            button.target = self
        }
        cancelButton.action = #selector(cancelClicked)
        cancelButton.keyEquivalent = "\u{1b}"
        useButton.action = #selector(useClicked)
        for view in [accountList, countdownLabel, cancelButton, useButton] {
            panel.contentView!.addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func confirm(items: [Item], seconds: TimeInterval = 30) async -> Decision {
        guard completion == nil, !Task.isCancelled, !items.isEmpty, seconds > 0 else { return .interrupted }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: .interrupted); return }
                confirmationID = id
                completion = { continuation.resume(returning: $0) }
                window?.title = L10n.text("自动使用重置卡")
                render(items)
                cancelButton.title = L10n.text("取消不使用")
                useButton.title = L10n.text("立即使用")
                deadline = ProcessInfo.processInfo.systemUptime + seconds
                updateCountdown()
                let timer = Timer(timeInterval: min(1, max(0.01, seconds)), repeats: true) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.updateCountdown() }
                }
                self.timer = timer
                RunLoop.main.add(timer, forMode: .common)
                window?.center()
                showWindow(nil)
                NSApp.activate(ignoringOtherApps: true)
                window?.makeKeyAndOrderFront(nil)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.confirmationID == id else { return }
                self?.finish(.interrupted)
            }
        }
    }

    private func render(_ items: [Item]) {
        let bodyHeight = min(300, CGFloat(items.count) * 66)
        window?.setContentSize(NSSize(width: 400, height: bodyHeight + 120))
        accountList.frame = NSRect(x: 20, y: 100, width: 360, height: bodyHeight)
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: CGFloat(items.count) * 66))
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.load().locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        for (index, item) in items.enumerated() {
            let y = document.bounds.height - CGFloat(index + 1) * 66
            let account = NSTextField(wrappingLabelWithString: item.account)
            account.frame = NSRect(x: 0, y: y + 26, width: 340, height: 36)
            account.font = .systemFont(ofSize: 13, weight: .semibold)
            account.maximumNumberOfLines = 2
            let expiration = NSTextField(labelWithString: L10n.text("到期时间：\(formatter.string(from: item.expiresAt))"))
            expiration.frame = NSRect(x: 0, y: y + 6, width: 340, height: 20)
            expiration.font = .systemFont(ofSize: 12)
            expiration.textColor = .secondaryLabelColor
            document.addSubview(account)
            document.addSubview(expiration)
        }
        accountList.documentView = document
        document.scroll(NSPoint(x: 0, y: max(0, document.bounds.height - bodyHeight)))
    }

    private func updateCountdown() {
        let remaining = max(0, Int(ceil(deadline - ProcessInfo.processInfo.systemUptime)))
        countdownLabel.stringValue = L10n.text("将在 \(remaining) 秒后自动使用以上重置卡")
        if remaining == 0 { finish(.use) }
    }

    @objc private func useClicked() { finish(.use) }
    @objc private func cancelClicked() { finish(.cancel) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { finish(.cancel); return false }

    private func finish(_ decision: Decision) {
        timer?.invalidate()
        timer = nil
        let callback = completion
        completion = nil
        confirmationID = nil
        window?.orderOut(nil)
        callback?(decision)
    }
}

@MainActor
private final class AutomaticResetContentView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        super.draw(dirtyRect)
    }
}
