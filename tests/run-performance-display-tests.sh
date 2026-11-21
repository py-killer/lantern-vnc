#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$PROJECT_DIR/../work/performance-display-tests"
mkdir -p "$TEST_DIR/module-cache"
xcrun swiftc -D LANTERN_TESTING -swift-version 5 -O -target arm64-apple-macosx13.0 \
  -module-cache-path "$TEST_DIR/module-cache" \
  -framework AppKit -framework Metal -framework MetalKit -framework QuartzCore \
  "$PROJECT_DIR/App/DesktopViewport.swift" "$PROJECT_DIR/App/FrameUpdateStore.swift" \
  "$PROJECT_DIR/App/MetalDesktop.swift" "$PROJECT_DIR/tests/performance_display_harness.swift" \
  -o "$TEST_DIR/performance-display-harness"
# A missing GPU/WindowServer is exit 77, never a passing result. This binary
# reads only test-owned Metal textures; it needs no screen-recording permission.
"$TEST_DIR/performance-display-harness" "$TEST_DIR"
