import Foundation
import CodexOrbCore

@main enum CodexOrbRecorder {
    static func main() async {
        let args = CommandLine.arguments
        let selectedHome = args.count == 3 && args[1] == "--account-home" ? args[2] : CodexAccountStore().nativeHome.path
        let accounts = CodexAccountStore().accounts(additionalHomes: CodexAccountStore.configuredHomes() + [selectedHome])
        guard !accounts.isEmpty else {
            fputs("No authenticated Codex accounts available\n", stderr)
            exit(1)
        }
        let result = await DailyAccountRecorder.record(accounts: accounts)
        print("Codex midnight recording: \(result.succeeded) succeeded, \(result.failed) failed")
        if result.failed > 0 { exit(1) }
    }
}
