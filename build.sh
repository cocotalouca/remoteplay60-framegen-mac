#!/bin/zsh
# Builds RemotePlay60.app from source (Apple Silicon, macOS 26+, Xcode or Command Line Tools).
#
#   ./build.sh            -> self-contained app (engine embedded) — use this
#   ./build.sh dev        -> rebuilds only build/RP60Engine.dylib, which a dev app loads from next to it.
#                            Keeps the Screen Recording permission between rebuilds while developing.
#   ./build.sh devapp     -> creates the dev app shell (needs Screen Recording permission once)
set -euo pipefail
cd "$(dirname "$0")"
APP="RemotePlay60.app"
TARGET="arm64-apple-macos26.0"
FRAMEWORKS=(-framework AppKit -framework ScreenCaptureKit -framework VideoToolbox -framework Metal -framework MetalFX
            -framework CoreVideo -framework CoreMedia -framework QuartzCore -framework SwiftUI -framework Carbon)
MODE="${1:-release}"

mkdir -p build
xcrun swiftc -O -swift-version 5 -target "$TARGET" -emit-library -module-name RP60Engine \
  -Xlinker -install_name -Xlinker @rpath/RP60Engine.dylib \
  -o build/RP60Engine.dylib src/Engine/*.swift "${FRAMEWORKS[@]}"
codesign -s - -f build/RP60Engine.dylib 2>/dev/null

if [[ "$MODE" == "dev" && -d "$APP" ]]; then
  echo "OK (engine only): build/RP60Engine.dylib"
  exit 0
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -O -swift-version 5 -target "$TARGET" src/Host.swift -o "$APP/Contents/MacOS/RemotePlay60"
cp src/Info.plist "$APP/Contents/Info.plist"

# App icon, drawn in code by the engine itself
rm -rf build/AppIcon.iconset
RP60_EXPORT_ICONSET="$PWD/build/AppIcon.iconset" "$APP/Contents/MacOS/RemotePlay60"
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

if [[ "$MODE" != "devapp" ]]; then
  mkdir -p "$APP/Contents/Frameworks"
  cp build/RP60Engine.dylib "$APP/Contents/Frameworks/"
fi
codesign -s - -f --deep --identifier local.remoteplay60 "$APP"
echo "OK: $APP"
