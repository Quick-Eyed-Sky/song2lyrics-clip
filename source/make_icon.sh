#!/bin/zsh
# Rebuilds AppIcon.icns (only needed if the icon design changes), then run ./build_app.sh again.
set -e
HERE="${0:A:h}"
mkdir -p "$HERE/.tmp_icon"; cp "$HERE/make_icon.swift" "$HERE/.tmp_icon/main.swift"
swiftc -O -swift-version 5 "$HERE/.tmp_icon/main.swift" -o "$HERE/.build_icon"
"$HERE/.build_icon" "$HERE"
cp "$HERE/AppIcon.iconset/icon_512x512@2x.png" "$HERE/AppIcon_preview.png"
iconutil -c icns "$HERE/AppIcon.iconset" -o "$HERE/AppIcon.icns"
rm -rf "$HERE/.tmp_icon" "$HERE/AppIcon.iconset" "$HERE/.build_icon"
echo "AppIcon.icns ready"
