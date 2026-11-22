#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$PROJECT_DIR/../work/browser-tests"
mkdir -p "$TEST_DIR/module-cache"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macosx13.0 \
  -module-cache-path "$TEST_DIR/module-cache" "$PROJECT_DIR/App/BrowserStore.swift" \
  "$PROJECT_DIR/tests/test_browser_store.swift" -o "$TEST_DIR/test-browser-store"
"$TEST_DIR/test-browser-store"
