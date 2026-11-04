#!/usr/bin/env bash
# Assemble GH Hub.app from the Swift build.
#
#   ./build.sh [version] [--universal]
set -euo pipefail

HERE0="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="${1:-$(cat "$HERE0/VERSION")}"
UNIVERSAL="${2:-}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE="$HERE/build/GH Hub.app"

cd "$HERE"
if [[ "$UNIVERSAL" == "--universal" ]]; then
  swift build -c release --arch arm64 --arch x86_64 >&2
  BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
else
  swift build -c release >&2
  BIN="$(swift build -c release --show-bin-path)"
fi

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN/gh-hub" "$BUNDLE/Contents/MacOS/gh-hub"
[[ -f Bundle/hub.icns ]] && cp Bundle/hub.icns "$BUNDLE/Contents/Resources/hub.icns"
sed "s/__VERSION__/$VERSION/g" Bundle/Info.plist > "$BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

# Ad-hoc signing is enough for the machine that built it.
codesign --force --deep --sign "${HUB_SIGN_IDENTITY:--}" "$BUNDLE" >&2
echo "$BUNDLE"
