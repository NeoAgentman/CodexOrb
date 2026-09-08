#!/usr/bin/env bash
# Import only vendor executables/resources; never copy user configuration.
set -euo pipefail
if [[ $# != 1 ]]; then
  echo "Usage: $0 /path/to/opentoken" >&2
  exit 2
fi
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_DIR="$ROOT_DIR/Sources/CodexOrbCore/Resources/Tools"
OPEN_TOKEN_BIN="$1"
codesign --verify --strict "$OPEN_TOKEN_BIN"
python3 - "$TOOLS_DIR/versions.json" "$OPEN_TOKEN_BIN" <<'CHECK'
import json, subprocess, sys
expected = json.load(open(sys.argv[1]))['opentoken']
actual = subprocess.check_output([sys.argv[2], '--version'], text=True).strip().split()[-1]
if actual != expected:
    raise SystemExit(f'opentoken: expected {expected}, got {actual}')
CHECK
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
