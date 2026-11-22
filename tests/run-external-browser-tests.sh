#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$PROJECT_DIR/../work/external-browser-tests"
mkdir -p "$TEST_DIR/module-cache"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macosx13.0 \
  -module-cache-path "$TEST_DIR/module-cache" -framework AppKit \
  "$PROJECT_DIR/App/ExternalBrowser.swift" "$PROJECT_DIR/tests/test_external_browser.swift" \
  -o "$TEST_DIR/test-external-browser"
if [[ "${EXTERNAL_BROWSER_PANEL_TESTS:-0}" == 1 ]]; then
  exec "$TEST_DIR/test-external-browser" --panel
fi
exec "$TEST_DIR/test-external-browser"
