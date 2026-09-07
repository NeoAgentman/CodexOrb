#!/usr/bin/env bash
# Import only vendor executables/resources; never copy user configuration.
set -euo pipefail
if [[ $# != 2 ]]; then
  echo "Usage: $0 /path/to/CodexBar.app/Contents/Helpers /path/to/opentoken" >&2
  exit 2
fi
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_DIR="$ROOT_DIR/Sources/CodexOrbCore/Resources/Tools"
VENDOR_DIR="$1"
OPEN_TOKEN_BIN="$2"
for binary in "$VENDOR_DIR/CodexBarCLI" "$VENDOR_DIR/CodexBarClaudeWatchdog" "$OPEN_TOKEN_BIN"; do
  codesign --verify --strict "$binary"
done
[[ -d "$VENDOR_DIR/CodexBar_CodexBarCore.bundle" ]]
python3 - "$TOOLS_DIR/versions.json" "$VENDOR_DIR/CodexBarCLI" "$OPEN_TOKEN_BIN" <<'PY'
import json, subprocess, sys
versions = json.load(open(sys.argv[1]))
for tool, binary in zip(('codexbar', 'opentoken'), sys.argv[2:]):
    actual = subprocess.check_output([binary, '--version'], text=True).strip().split()[-1]
    if actual != versions[tool]:
        raise SystemExit(f'{tool}: expected {versions[tool]}, got {actual}')
PY
cp "$VENDOR_DIR/CodexBarCLI" "$TOOLS_DIR/codexbar"
cp "$VENDOR_DIR/CodexBarClaudeWatchdog" "$TOOLS_DIR/CodexBarClaudeWatchdog"
# Remove stale vendor resources only after validating the new payload.
if [[ -d "$TOOLS_DIR/CodexBar_CodexBarCore.bundle" ]]; then
  mv "$TOOLS_DIR/CodexBar_CodexBarCore.bundle" "$(mktemp -d)/CodexBar_CodexBarCore.bundle"
fi
ditto "$VENDOR_DIR/CodexBar_CodexBarCore.bundle" "$TOOLS_DIR/CodexBar_CodexBarCore.bundle"
if [[ "$OPEN_TOKEN_BIN" != "$TOOLS_DIR/opentoken" ]]; then
  cp "$OPEN_TOKEN_BIN" "$TOOLS_DIR/opentoken"
fi
python3 - "$TOOLS_DIR" <<'PY'
from pathlib import Path
import hashlib, sys
root = Path(sys.argv[1])
files = sorted(p for p in root.rglob('*') if p.is_file() and p.name not in ('SHA256SUMS', '.DS_Store'))
(root/'SHA256SUMS').write_text(''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.relative_to(root)}\n' for p in files))
PY
echo "Imported and pinned local CLI payloads."
