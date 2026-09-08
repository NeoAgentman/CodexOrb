# CodexOrb

A small native macOS floating window that displays Codex quota remaining and today's local AI token usage. It is
built with the macOS SDK. Codex quota and reset cards use a locally installed `codex app-server`;
OpenToken is bundled for machine-wide local token statistics.

## Requirements

- macOS 14 or newer
- Swift 6.2 Command Line Tools (building only)
- Codex CLI or Codex/ChatGPT App with a compatible Codex runtime (verified schema: 0.153.4)
- File-based Codex OAuth login state and network access for quota queries
- Local AI tool usage logs for token statistics

CodexOrb searches PATH, `~/.local/bin`, Homebrew locations, and Codex/ChatGPT application resources.
It probes the actual app-server schema and skips incompatible candidates. It never updates the external
Codex installation. Each operation starts a private stdio process with the selected account's `CODEX_HOME`
and `cli_auth_credentials_store="file"`, then closes and reaps that process. No model turn is created.
Account identity is checked before and after quota reads; optional backend account IDs are also checked.

```sh
codex app-server --stdio -c 'cli_auth_credentials_store="file"'
opentoken preview --since <today> --json
```

## Source checkout

The repository includes pinned OpenToken 0.3.27 and SHA256SUMS. CodexBar and its companion resources
are no longer bundled. Existing CodexBar profile-home configuration is still read for account discovery.
`Scripts/import_cli_tools.sh /path/to/opentoken` is an optional maintainer tool. It verifies the pinned
version/signature and regenerates checksums, without copying credentials or configuration.

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
./Scripts/check_app_ui.sh
```

## Build a local app bundle

```sh
cd CodexOrb
./Scripts/build_app.sh
open CodexOrb.app
```

OpenToken lives in `Sources/CodexOrbCore/Resources/Tools`. Packaging validates checksums, copies it
into `Contents/Helpers`, and signs the copy. A validated managed update takes precedence over the bundled
copy; an invalid managed update falls back to the bundle. A missing bundled copy is an error.
See `Sources/CodexOrbCore/Resources/Tools/NOTICE.md` for provenance. OpenToken is included at the
repository owner's explicit request; its redistribution terms remain unverified.

`swift run CodexOrbCoreChecks --live-gui-environment` is an **opt-in live quota read** using app-server;
it never consumes a reset. Normal checks use only local fake accounts and a fake protocol peer.

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
- 更新 CLI: updates only OpenToken, retaining its previous version on failure. The action runs immediately,
  and closing Settings preserves progress. Codex runtime installation/update is managed externally.

Save persists the selection locally and refreshes the capsule. The OpenToken total remains a machine-wide all-tool total; it is not attributed to the selected account.

CLI updates live under `~/Library/Application Support/CodexOrb/CLI/<tool>/`. Each update uses a new staging
directory, validates the candidate's signature, version and actual JSON report, then atomically switches
that tool's `current.json` to a new immutable release directory. The app picks up the new version on its next
invocation. Existing release directories remain available to running processes;
temporary update files are moved to Trash. Separate file locks prevent concurrent updates of the same tool.
The application bundle, global CLI installations and background service definitions are not modified.

OpenToken's `self-update` runs on a staged executable with writes restricted to staging and temporary
output. Signature, version and token JSON validation must pass before activation. No upload or daemon
operation is invoked. The base version comes from `versions.json`.

Codex app-server and OpenToken refresh concurrently but commit their results independently. Each source makes an initial
request and, after a failure, retries up to three times with five seconds between attempts. A successful source updates
the UI immediately while the other continues retrying. If one source still fails, it keeps its last successful value
and the capsule shows an amber status dot.


## Reset cards and confirmation

Clicking a known, available card performs a read-only preflight and then opens a confirmation dialog
showing the account and card expiry. **Only “Use 1 card” sends the mutation. Cancel, dismiss and the default
Return key do not consume a card.** Card IDs stay attached when cards are sorted. Unknown details,
expired cards, unsupported reset types and cards with no ID cannot be redeemed. Non-expiring known cards
are shown separately from count-only placeholders.

The protocol calls are `account/rateLimits/read` and `account/rateLimitResetCredit/consume`.
The `codex` bucket is selected before matching 300/10080-minute windows. Missing data is not treated as
zero usage. Account operations are serialized, with a file lock preventing overlap across app instances.
Ordinary refreshes wait for the UI's reset operation; results from a previous selected account are discarded.

Before a send, a pending record is atomically saved in
`~/Library/Application Support/CodexOrb/ResetOperations/<identity-hash>/pending.json`.
It contains only the account identity hash, card ID, request UUID, timestamp and optional outcome, never
a token. Closing the app or losing the response preserves the same UUID. “Recover previous reset” requires
confirmation and reuses that UUID; it does not create a separate redemption. Do not manually delete pending
records to retry an uncertain operation.

`reset` and `alreadyRedeemed` are successful outcomes; `noCredit` and `nothingToReset` do not apply a reset.
Every outcome is followed by a fresh quota read. A known success plus failed refresh remains a known success;
recovery only rereads quota. An uncertain response retains its pending operation. Other card consumption
stays disabled until recovery completes. Cancellation cannot undo a request already sent.

Offline interaction checks (no real redemption):

```sh
./Scripts/check_app_ui.sh
```
