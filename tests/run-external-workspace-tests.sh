#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$PROJECT_DIR/../work/external-browser-tests"
mkdir -p "$TEST_DIR/controller-module-cache"
xcrun swiftc -O -D APP_UI_HARNESS -D BROWSER_HARNESS -D LANTERN_TESTING \
  -swift-version 5 -target arm64-apple-macosx13.0 -module-cache-path "$TEST_DIR/controller-module-cache" \
  -import-objc-header "$PROJECT_DIR/native/VNCBridge.h" \
  -framework AppKit -framework Metal -framework MetalKit -framework QuartzCore \
  -framework Network -framework Security -framework WebKit \
  "$PROJECT_DIR"/App/*.swift "$PROJECT_DIR/tests/external_workspace_harness.swift" \
  "$PROJECT_DIR/build/VNCBridge.o" "$PROJECT_DIR/build/vnc/libvncclient.a" \
  "$PROJECT_DIR/build/jpeg/libjpeg.a" -lz -o "$TEST_DIR/external-workspace-harness"
exec "$TEST_DIR/external-workspace-harness" "$TEST_DIR/external-workspace-report.json"
