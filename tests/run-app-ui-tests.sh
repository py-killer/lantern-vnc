#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Uses only an owned offscreen window, synthetic pixels, temporary preferences,
# and local control actions. No VNC connection or global computer input.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
TEST_DIR="$PROJECT_DIR/../work/display-tests"
REPORT_FILE="$TEST_DIR/app-ui-report.json"

if [[ "$(uname -s)" != Darwin ]]; then
  echo "UNAVAILABLE: native app UI tests require macOS and Metal access (exit 77)." >&2
  exit 77
fi

for dependency in "$BUILD_DIR/VNCBridge.o" "$BUILD_DIR/vnc/libvncclient.a" "$BUILD_DIR/jpeg/libjpeg.a"; do
  if [[ ! -f "$dependency" ]]; then
    echo "Missing build dependency: $dependency" >&2
    echo "Run scripts/build-app.sh before running the app UI tests." >&2
    exit 1
  fi
done

mkdir -p "$TEST_DIR/ui-module-cache"
xcrun swiftc -O -D APP_UI_HARNESS -swift-version 5 -target arm64-apple-macosx13.0 \
  -module-cache-path "$TEST_DIR/ui-module-cache" \
  -import-objc-header "$PROJECT_DIR/native/VNCBridge.h" \
  -framework AppKit -framework Metal -framework MetalKit -framework QuartzCore -framework Network -framework Security \
  "$PROJECT_DIR/App/App.swift" "$PROJECT_DIR/App/WindowPlacement.swift" "$PROJECT_DIR/App/DeviceStore.swift" "$PROJECT_DIR/App/ConnectionPreferences.swift" "$PROJECT_DIR/App/PasswordStore.swift" "$PROJECT_DIR/App/NetworkDiscovery.swift" "$PROJECT_DIR/App/VNCDiscoveryController.swift" \
  "$PROJECT_DIR/App/NetworkLatency.swift" "$PROJECT_DIR/App/VNCSession.swift" "$PROJECT_DIR/App/DesktopViewport.swift" \
  "$PROJECT_DIR/App/FrameUpdateStore.swift" "$PROJECT_DIR/App/MetalDesktop.swift" "$PROJECT_DIR/tests/app_ui_harness.swift" \
  "$BUILD_DIR/VNCBridge.o" "$BUILD_DIR/vnc/libvncclient.a" "$BUILD_DIR/jpeg/libjpeg.a" \
  -lz -o "$TEST_DIR/app-ui-harness"

# Never leave an earlier passing report behind after an unavailable or failed run.
rm -f "$REPORT_FILE"
# The harness reports missing GPU/WindowServer access as exit 77, which is
# propagated unchanged and must never be interpreted as a passing native test.
exec "$TEST_DIR/app-ui-harness" "$REPORT_FILE"
