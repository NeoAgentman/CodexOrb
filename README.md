# CodexOrb

A small native macOS floating window that displays Codex quota remaining and today's local AI token usage. It is
built with the macOS SDK and includes pinned `codexbar` and `opentoken` CLI binaries.
The app and midnight recorder run their own bundled copies; no Homebrew, CLI installation or PATH setup is required.

## Requirements

- macOS 14 or newer
- Swift 6.2 Command Line Tools (building only)
- Existing Codex OAuth login state and network access for quota queries
- Local AI tool usage logs for token statistics

CodexOrb delegates authentication to the bundled CodexBar CLI; credentials are not copied into the app. It runs:

```sh
codexbar usage --provider codex --source oauth --format json --json-only
opentoken preview --since <today> --json
```

## Prepare a source checkout

CodexBar binaries are excluded from Git. Obtain the pinned CodexBar universal app from
[the official 0.56.7 release](https://github.com/steipete/CodexBar/releases/tag/v0.56.7)
then import it alongside the included OpenToken 0.3.27 executable:

```sh
./Scripts/import_cli_tools.sh /path/to/CodexBar.app/Contents/Helpers "$PWD/Sources/CodexOrbCore/Resources/Tools/opentoken"
```

Python 3 is required for this import step. The script checks versions and signatures and generates
local checksums. It does not import OAuth state, keys, logs, or account configuration.
OpenToken is included at the repository owner's explicit request; its redistribution license has not
been established. No application bundle is published. Local app bundles remain usable without external tools.

## Run during development

```sh
cd CodexOrb
swift run CodexOrb
```

## Test

```sh
cd CodexOrb
swift run CodexOrbCoreChecks
```

The checks use fixed JSON fixtures and do not call a real account. They are a small executable instead of an XCTest
bundle so they work with the standalone Command Line Tools installation.

## Build a local app bundle

```sh
cd CodexOrb
./Scripts/build_app.sh
open CodexOrb.app
```

Pinned tools live in `Sources/CodexOrbCore/Resources/Tools` (about 53 MB): CodexBar 0.56.7 and OpenToken 0.3.27.
SwiftPM copies them into a resource bundle for development. App packaging validates SHA-256 checksums,
copies tools and companion resources into `Contents/Helpers`, then signs them. Both the GUI and recorder
resolve this location relative to their executable, so the built app can be relocated.
They check for a validated CodexOrb-managed update on each invocation and otherwise use the bundled copy.
A missing or corrupt managed executable falls back to the bundled copy. Missing bundled tools produce
an error instead of silently using a global installation.
Explicit `bundledExecutableDirectory: nil` is reserved for external-tool integration tests.

Run `swift run CodexOrbCoreChecks --live-gui-environment` to query both bundled sources with a minimal PATH.
See `Sources/CodexOrbCore/Resources/Tools/NOTICE.md` for provenance and update instructions.
OpenToken redistribution terms have not been established; the imported binary is currently for local use.

The bundle is ad-hoc signed for local use. Distribution to other Macs requires an appropriate Developer ID signing
and notarization workflow.

The app icon source is `Resources/AppIcon.png`. The build script generates the complete macOS `.icns` size set.

## Controls

- Hover over the orb to expand the capsule; move away to collapse it.
- Click the reset-card stack to open the available reset cards.
- Drag to move; the position is restored on the next launch.
- Right-click to refresh, open Settings, or quit.
- Collapsed orb: weekly remaining quota and signed pace delta. Pace is hidden when weekly quota is exhausted.
- Expanded capsule: adds reset credits, today's all-tool token total including cached reads, and the top model.

## Settings

Right-click the capsule and choose **Settings…** to change:

- 胶囊显示账号: shows the current Codex account and lets you select another account, then Save. Only Codex quota is supported.
- 添加 Codex 账号: starts browser login through the installed Codex CLI in a private home under `~/Library/Application Support/CodexOrb/Accounts/`. Complete authorization in the browser; the existing system login is preserved. Login times out after three minutes.
- 刷新账号: discovers the native Codex login, accounts added here, and CodexBar's configured `codexProfileHomePaths`. Account labels show email and plan; internal identity keys are not displayed. Credentials are never copied into app preferences.
- Automatic refresh: 1, 5, 10, 15, or 30 minutes, or 1 hour. The default is 5 minutes.
- 每天 00:00 记录周额度: enable/disable the user LaunchAgent and daily capsule indicator. Save applies the change. Disabling moves the plist to Trash and preserves history.
- 更新 CLI: check and update CodexBar and OpenToken independently. Each has its own progress and result;
  a failure preserves that tool's previous version. Closing/reopening Settings preserves progress. This
  action runs immediately and does not require Save; it validates quota using the currently saved Codex account.

Save persists the selection locally and refreshes the capsule. The OpenToken total remains a machine-wide all-tool total; it is not attributed to the selected account.

CLI updates live under `~/Library/Application Support/CodexOrb/CLI/<tool>/`. Each update uses a new staging
directory, validates the candidate's signature, version and actual JSON report, then atomically switches
that tool's `current.json` to a new immutable release directory. The app and midnight recorder pick up the
new version on their next invocation. Existing release directories remain available to running processes;
temporary update files are moved to Trash. Separate file locks prevent concurrent updates of the same tool.
The application bundle, global CLI installations and background service definitions are not modified.

CodexBar updates use the latest stable official GitHub macOS CLI archive for the app's architecture, verify
the release asset SHA-256, and preserve the accompanying resource bundle and VERSION file. OpenToken's
official `self-update` runs on a staged executable with writes restricted to its staging directory and
temporary output files. Its update channel and rollout rules still apply; a missing channel/login or failed
live check leaves the old version active. No new upload or daemon operation is invoked. The updater needs
network access, and candidate quota validation uses the existing account. The base CLI versions displayed
in Settings come from `versions.json`, avoiding CodexBar's host-app version reporting behavior.

CodexBar and OpenToken refresh concurrently but commit their results independently. Each source makes an initial
request and, after a failure, retries up to three times with five seconds between attempts. A successful source updates
the UI immediately while the other continues retrying. If one source still fails, it keeps its last successful value
and the capsule shows an amber status dot.

## Daily weekly-quota consumption

When enabled, the capsule shows `−3.2% · sol`: 3.2 percentage points of the total weekly allowance consumed today, not 3.2% of the remaining allowance. Partial-day and reset-estimate metadata remain in the local journal.

The bundled `CodexOrbRecorder` runs via `com.local.CodexOrb.daily-quota` at local 00:00 and when the agent is loaded (including login). A sleeping Mac runs a missed calendar event on wake; it does not wake the Mac. A powered-off or logged-out Mac cannot sample at midnight. Late first samples begin a partial day; they do not reconstruct earlier consumption. The helper discovers and records all available Codex accounts independently, including accounts not selected in the capsule. It retries each failure twice with ten seconds between attempts; one failed account does not block the others. It reports aggregate success/failure counts and exits nonzero if any account failed. Subsequent successful app refreshes can establish a partial baseline.

Successful app quota refreshes also update the journal. A new local day starts a new baseline. Detected weekly/manual resets add the observed post-reset usage and mark the result as estimated: usage between the last pre-reset observation and the reset cannot be recovered, and multiple resets between observations may be missed. Account email and workspace account ID are hashed to isolate records without storing email text; an unidentified account is not recorded.

The app and recorder use a file lock and atomic replacement for `~/Library/Application Support/CodexOrb/daily-quota.json`. This directory also contains `recorder.log` and `recorder-error.log`. Do not move the installed app while the LaunchAgent is enabled; turn the setting off and back on from the new location to update its executable path.
