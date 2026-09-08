#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${ROOT_DIR}/CodexOrb.app"
ICON_SOURCE="${ROOT_DIR}/Resources/AppIcon.png"
ICONSET_DIR="${ROOT_DIR}/.build/AppIcon.iconset"

cd "${ROOT_DIR}"
(cd Sources/CodexOrbCore/Resources/Tools && shasum -a 256 -c SHA256SUMS)
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

if [[ -e "${APP_DIR}" ]]; then
  if command -v trash >/dev/null 2>&1; then
    trash "${APP_DIR}"
  else
    /usr/bin/osascript - "${APP_DIR}" <<'APPLESCRIPT'
on run argv
  tell application "Finder" to delete POSIX file (item 1 of argv)
end run
APPLESCRIPT
  fi
fi

mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"
cp "${BIN_DIR}/CodexOrb" "${APP_DIR}/Contents/MacOS/CodexOrb"
cp -R "${ROOT_DIR}/Sources/CodexOrbCore/Resources/Tools" "${APP_DIR}/Contents/Helpers"
chmod 755 "${APP_DIR}/Contents/Helpers/opentoken"
cp "${ROOT_DIR}/Resources/Info.plist" "${APP_DIR}/Contents/Info.plist"

mkdir -p "${ICONSET_DIR}"
sips -z 16 16 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_16x16.png" >/dev/null
sips -z 32 32 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_32x32.png" >/dev/null
sips -z 64 64 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_128x128.png" >/dev/null
sips -z 256 256 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_256x256.png" >/dev/null
sips -z 512 512 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_512x512.png" >/dev/null
sips -z 1024 1024 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_512x512@2x.png" >/dev/null
iconutil -c icns "${ICONSET_DIR}" -o "${APP_DIR}/Contents/Resources/AppIcon.icns"

for helper in opentoken; do
  codesign --force --sign - "${APP_DIR}/Contents/Helpers/${helper}"
done
codesign --force --deep --sign - "${APP_DIR}"
codesign --verify --deep --strict "${APP_DIR}"

echo "Built ${APP_DIR}"
