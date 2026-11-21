#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$PROJECT_DIR/../work/window-placement-tests"
mkdir -p "$TEST_DIR/module-cache"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macosx13.0 \
  -module-cache-path "$TEST_DIR/module-cache" -framework AppKit \
  "$PROJECT_DIR/App/WindowPlacement.swift" "$PROJECT_DIR/tests/test_window_placement.swift" \
  -o "$TEST_DIR/test-window-placement"
# --geometry-only never accesses NSApplication, screens, windows, or defaults.
# Full native checks use only a UUID frame key and invisible test-owned windows.
"$TEST_DIR/test-window-placement" "$@"
