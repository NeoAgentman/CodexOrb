# CodexOrb

A small native macOS floating window that displays Codex quota remaining and today's local AI token usage. It is
built with the macOS SDK and includes pinned `codexbar` and `opentoken` CLI binaries.
The app runs its own bundled copies; no Homebrew, CLI installation or PATH setup is required.

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

## Source checkout

The repository includes both pinned CLI binaries, CodexBar companion resources, its license,
and SHA256SUMS. A fresh clone can build directly; no CodexBar app download, installation,
or import step is required.

`Scripts/import_cli_tools.sh` is an optional maintainer tool for updating vendor payloads.
It requires Python 3, validates the versions in `versions.json` and executable signatures,
and regenerates checksums. It copies no OAuth state, keys, logs, or account configuration.

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

To check capsule resizing and scaled mouse hit areas without querying an account:

```sh
swift build
swiftc -parse-as-library -I .build/debug/Modules Sources/CodexOrb/CapsuleGeometry.swift Sources/CodexOrb/OrbView.swift Sources/CodexOrb/OrbPanelController.swift Sources/CodexOrb/ResetCardsView.swift Sources/CodexOrb/QuotaDetailsView.swift Scripts/check_capsule_resize.swift .build/debug/CodexOrbCore.build/*.o -o /tmp/codexorb-resize-checks
/tmp/codexorb-resize-checks
```

## Build a local app bundle

```sh
cd CodexOrb
./Scripts/build_app.sh
open CodexOrb.app
```

Pinned tools live in `Sources/CodexOrbCore/Resources/Tools` (about 53 MB): CodexBar 0.56.7 and OpenToken 0.3.27.
SwiftPM copies them into a resource bundle for development. App packaging validates SHA-256 checksums,
copies tools and companion resources into `Contents/Helpers`, then signs them. The GUI resolves this location
relative to its executable, so the built app can be relocated.
They check for a validated CodexOrb-managed update on each invocation and otherwise use the bundled copy.
A missing or corrupt managed executable falls back to the bundled copy. Missing bundled tools produce
an error instead of silently using a global installation.
Explicit `bundledExecutableDirectory: nil` is reserved for external-tool integration tests.

Run `swift run CodexOrbCoreChecks --live-gui-environment` to query both bundled sources with a minimal PATH.
See `Sources/CodexOrbCore/Resources/Tools/NOTICE.md` for provenance and update instructions.
OpenToken is included at the repository owner's explicit request; its redistribution terms remain unverified.

The bundle is ad-hoc signed for local use. Distribution to other Macs requires an appropriate Developer ID signing
and notarization workflow.

The app icon source is `Resources/AppIcon.png`. The build script generates the complete macOS `.icns` size set.

## Controls

- Hover inside the orb to expand the capsule; move away to collapse it. A 6-point band along the visible rounded edge is reserved for resizing and highlights on hover.
- Click the reset-card stack to open the available reset cards.
- Drag inside to move, or drag an edge to resize proportionally from 100% to 150%. The expanded maximum is 264 × 84 points; the collapsed maximum is 90 × 84 points. Position and size are restored on the next launch.
- Double-click the token total to refresh; right-click to refresh, open Settings, or quit.
- Collapsed orb: weekly remaining quota and 5-hour remaining quota. The pace indicator remains on the quota ring and is hidden when weekly quota is exhausted.
- Expanded capsule: adds reset credits, today's all-tool token total including cached reads, and the top model.

## Settings

Right-click the capsule and choose **Settings…** to change:

- 胶囊显示账号: shows the current Codex account and lets you select another account, then Save. Only Codex quota is supported.
- 添加 Codex 账号: starts browser login through the installed Codex CLI in a private home under `~/Library/Application Support/CodexOrb/Accounts/`. Complete authorization in the browser; the existing system login is preserved. Login times out after three minutes.
- 刷新账号: discovers the native Codex login, accounts added here, and CodexBar's configured `codexProfileHomePaths`. Account labels show email and plan; internal identity keys are not displayed. Credentials are never copied into app preferences.
- Automatic refresh: 1, 5, 10, 15, or 30 minutes, or 1 hour. The default is 5 minutes.
- 默认展开胶囊: keep the capsule expanded after launch and when the pointer leaves it. When disabled, the capsule retains its existing hover-to-expand behavior.
- 开机启动: controls the macOS login item immediately, independently of Save/Cancel and account login. Reads the system status each time settings becomes active; pending approval includes a link to system login item settings.
- 更新 CLI: check and update CodexBar and OpenToken independently. Each has its own progress and result;
  a failure preserves that tool's previous version. Closing/reopening Settings preserves progress. This
  action runs immediately and does not require Save; it validates quota using the currently saved Codex account.

Save persists the selection locally and refreshes the capsule. The OpenToken total remains a machine-wide all-tool total; it is not attributed to the selected account.

CLI updates live under `~/Library/Application Support/CodexOrb/CLI/<tool>/`. Each update uses a new staging
directory, validates the candidate's signature, version and actual JSON report, then atomically switches
that tool's `current.json` to a new immutable release directory. The app picks up the new version on its next
invocation. Existing release directories remain available to running processes;
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
