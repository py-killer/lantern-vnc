#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
APP_DIR="${APP_OUTPUT:-$BUILD_DIR/artifacts.noindex/Lantern VNC.app}"
# CMake is incremental. Always check vendored sources so an existing archive
# cannot silently omit a changed client read hook or codec fix.
"$PROJECT_DIR/scripts/build-deps.sh"
mkdir -p "$BUILD_DIR/module-cache" "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources/Licenses"
xcrun clang -O3 -arch arm64 -mmacosx-version-min=13.0 -std=c11 -Wall -Wextra -Werror \
  -I"$PROJECT_DIR/vendor/libvncserver/include" -I"$BUILD_DIR/vnc/include" \
  -c "$PROJECT_DIR/native/VNCBridge.c" -o "$BUILD_DIR/VNCBridge.o"
xcrun swiftc -O -whole-module-optimization -swift-version 5 -target arm64-apple-macosx13.0 \
  -module-cache-path "$BUILD_DIR/module-cache" \
  -import-objc-header "$PROJECT_DIR/native/VNCBridge.h" \
  -framework AppKit -framework Metal -framework MetalKit -framework QuartzCore -framework Network -framework Security -framework WebKit \
  "$PROJECT_DIR"/App/*.swift \
  "$BUILD_DIR/VNCBridge.o" "$BUILD_DIR/vnc/libvncclient.a" "$BUILD_DIR/jpeg/libjpeg.a" -lz \
  -o "$APP_DIR/Contents/MacOS/LanternVNC"
cp "$PROJECT_DIR/App/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$PROJECT_DIR/vendor/libvncserver/COPYING" "$APP_DIR/Contents/Resources/Licenses/LibVNCClient-GPL-2.txt"
cp "$PROJECT_DIR/vendor/libjpeg-turbo/LICENSE.md" "$APP_DIR/Contents/Resources/Licenses/libjpeg-turbo.txt"
cp "$PROJECT_DIR/vendor/libjpeg-turbo/README.ijg" "$APP_DIR/Contents/Resources/Licenses/IJG.txt"
if [[ -f "$PROJECT_DIR/App/AppIcon.icns" ]]; then cp "$PROJECT_DIR/App/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"; fi
codesign --force --sign - --identifier local.lantern.vnc "$APP_DIR"
echo "$APP_DIR"
