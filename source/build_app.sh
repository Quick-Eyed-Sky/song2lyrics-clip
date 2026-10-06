#!/bin/zsh
# Builds the app next to this folder from the .swift files ("Song2Lyrics Clip.app" unless APP_NAME says otherwise).
# Needs only the Xcode Command Line Tools (swiftc). Nothing else is installed.
#
#   cd source && ./build_app.sh              (APP_NAME="Other Name" BUNDLE_ID=com.example.x ./build_app.sh to rename)

set -e
if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc was not found. Install Apple's command line tools first (a few minutes, no Apple ID needed):"
  echo "    xcode-select --install"
  echo "then run this script again."
  exit 1
fi
HERE="${0:A:h}"
ROOT="${HERE:h}"
NAME="${APP_NAME:-Song2Lyrics Clip}"
BUNDLE="${BUNDLE_ID:-com.quickeyedsky.song2lyrics-clip}"
EXEC="${NAME// /}"
APP="${OUT_DIR:-$ROOT}/$NAME.app"
BUILD="$HERE/.build"
# lyrics.py: the copy next to this script if there is one (the published repository), else the song-lyrics skill's.
if [ -f "$HERE/lyrics.py" ]; then SKILL="$HERE"; else SKILL="$HOME/.claude/skills/song-lyrics/scripts"; fi

# One version number, defined once, in Engine.swift.
VERSION=$(grep -E 'static let version = ' "$HERE/Engine.swift" | sed -E 's/.*"([^"]+)".*/\1/')
echo "Building $NAME $VERSION ..."

rm -rf "$BUILD"; mkdir -p "$BUILD"
swiftc -O -swift-version 5 -parse-as-library \
  -target arm64-apple-macos14.0 \
  "$HERE/Engine.swift" "$HERE/LyricsFiles.swift" "$HERE/SongLyricsApp.swift" \
  -o "$BUILD/$EXEC"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/$EXEC" "$APP/Contents/MacOS/$EXEC"
[ -f "$HERE/AppIcon.icns" ] && cp "$HERE/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# A copy of the skill's script, used only if the skill folder is ever moved (the skill's own copy comes first).
mkdir -p "$APP/Contents/Resources/scripts"
cp "$HERE/clip.py" "$APP/Contents/Resources/scripts/"
if [ -f "$SKILL/lyrics.py" ]; then
  cp "$SKILL/lyrics.py" "$APP/Contents/Resources/scripts/"
  cp -R "$SKILL/numba_standin" "$APP/Contents/Resources/scripts/" 2>/dev/null || true
  find "$APP/Contents/Resources/scripts" -name '__pycache__' -prune -exec rm -rf {} +
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE</string>
  <key>CFBundleExecutable</key><string>$EXEC</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHumanReadableCopyright</key><string>Copyright (C) 2026 Jean-Pascal (Quick-Eyed Sky). Engine: whisper.cpp (MIT) with the large-v3-turbo model.</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Song</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array><string>public.audio</string><string>public.folder</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 && echo "Signed (ad hoc)."
echo "Done: $APP"
