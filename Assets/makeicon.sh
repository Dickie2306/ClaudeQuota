#!/bin/zsh
# Regenerate AppIcon.icns from makeicon.swift
set -euo pipefail
cd "$(dirname "$0")"

swift makeicon.swift icon_1024.png

ICONSET="AppIcon.iconset"
rm -rf "$ICONSET" && mkdir "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z $s $s icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o AppIcon.icns
rm -rf "$ICONSET" icon_1024.png
echo "wrote Assets/AppIcon.icns"
