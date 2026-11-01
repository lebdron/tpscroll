#!/bin/bash
# Build build/TPScroll.app (default) or build/TPRec.app (`./build.sh tprec`).
# Signs ad-hoc unless SIGN_ID is set, e.g. SIGN_ID="Apple Development: Name (TEAMID)" ./build.sh
# (a stable signing identity keeps the privacy grants valid across rebuilds; ad-hoc builds need re-granting).
set -euo pipefail
cd "$(dirname "$0")"
TARGET="${1:-tpscroll}"
case "$TARGET" in
  # the agent is checked with Swift 6 strict concurrency; tprec is a throwaway diagnostic tool (Swift 5 mode)
  tpscroll) NAME=TPScroll; EXE=tpscroll; SRC=Sources/tpscroll.swift; ID=io.github.lebdron.tpscroll; LANG=6 ;;
  tprec)    NAME=TPRec;    EXE=tprec;    SRC=tools/tprec/tprec.swift; ID=io.github.lebdron.tprec;    LANG=5 ;;
  *) echo "usage: $0 [tpscroll|tprec]" >&2; exit 2 ;;
esac
ARCH="$(uname -m)"
APP="build/$NAME.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
# explicit deployment target: newer toolchains may default to an OS newer than the one running
swiftc -O -swift-version "$LANG" -target "$ARCH-apple-macos13" -o "$APP/Contents/MacOS/$EXE" "$SRC"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>$EXE</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign "${SIGN_ID:--}" --identifier "$ID" "$APP"
echo "built $APP (signed: ${SIGN_ID:-ad-hoc})"
