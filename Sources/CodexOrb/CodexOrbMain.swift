import AppKit

@main
enum CodexOrbMain {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--enable-daily-quota") || CommandLine.arguments.contains("--disable-daily-quota") {
            do {
                try DailyQuotaLaunchAgent.setEnabled(CommandLine.arguments.contains("--enable-daily-quota"),
                                                    accountHome: AppSettings.load().accountHome)
                print("Daily quota recorder enabled: \(DailyQuotaLaunchAgent.isEnabled)")
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                exit(1)
            }
            return
        }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}
