# Bundled CLI provenance

Verified 2026-09-07 for this local CodexOrb build:

- codexbar: CodexBar 0.56.7, imported from the official universal macOS release archive.
  Upstream: https://github.com/steipete/CodexBar/releases/tag/v0.56.7
  Includes CodexBarClaudeWatchdog and CodexBar_CodexBarCore.bundle from the same verified archive.
  Upstream license is preserved in CodexBar-LICENSE.txt.
- opentoken: 0.3.27, copied from the user's installed ~/.local/bin/opentoken.
  Upstream source and redistribution license have not been established; this binary is included at the repository owner's explicit request.
  Redistribution terms remain unverified.

Both CLI binaries contain arm64 and x86_64 slices and link only macOS system libraries.
No account files, tokens, logs or service definitions are included.
SHA256SUMS pins all imported files. App packaging re-signs executable copies; vendor originals remain unchanged.

To upgrade, replace the relevant binary AND its companion resources from a trusted matching release,
update this notice and licenses, regenerate SHA256SUMS, then run the core checks and the bundled live check.
Settings can run OpenToken self-update on an isolated temporary copy and enable a validated update in
CodexOrb's Application Support directory. The bundled originals are unchanged; no OpenToken service is installed.
versions.json records the imported base versions independently of the host application's Info.plist.

Both CLI payloads, companion resources, licenses and SHA256SUMS are tracked in Git.
Fresh source checkouts build directly. Scripts/import_cli_tools.sh is only needed for maintainer updates.
CodexBar archive SHA-256: a5e2cbcddde705e91f6ad8fe673f07b73efec2fe2087873174486c6dedeac69e.
OpenToken self-update reported channel latest=0.3.27 on 2026-09-07.
