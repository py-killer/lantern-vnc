#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$PROJECT_DIR/../work/display-tests"
mkdir -p "$TEST_DIR/module-cache" "$TEST_DIR/screenshots"
xcrun swiftc -swift-version 5 -O -module-cache-path "$TEST_DIR/module-cache" \
  "$PROJECT_DIR/App/DesktopViewport.swift" "$PROJECT_DIR/tests/test_viewport.swift" \
  -o "$TEST_DIR/test-viewport"
"$TEST_DIR/test-viewport"
xcrun swiftc -swift-version 5 -O -module-cache-path "$TEST_DIR/module-cache" \
  -framework AppKit -framework Metal -framework MetalKit -framework QuartzCore \
  "$PROJECT_DIR/App/DesktopViewport.swift" "$PROJECT_DIR/App/FrameUpdateStore.swift" "$PROJECT_DIR/App/MetalDesktop.swift" \
  "$PROJECT_DIR/tests/native_display_harness.swift" -o "$TEST_DIR/native-display-harness"
# GPU or WindowServer unavailability is reported as exit 77, never a passing
# native test. Only an owned offscreen window and generated pixels are used.
LANTERN_TEST_VERSION="${LANTERN_TEST_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/App/Info.plist")}" \
  "$TEST_DIR/native-display-harness" "$TEST_DIR/screenshots"
