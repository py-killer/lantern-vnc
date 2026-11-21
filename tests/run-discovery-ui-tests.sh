#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Only synthetic LAN plans, an injected fake scanner, and owned offscreen UI.
# No real network, application activation, global events, or Keychain access.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$PROJECT_DIR/../work/discovery-ui-tests"
REPORT="$TEST_DIR/discovery-ui-report.json"

if [[ "$(uname -s)" != Darwin ]]; then
  echo 'UNAVAILABLE: discovery UI tests require macOS WindowServer (exit 77).' >&2
  exit 77
fi

mkdir -p "$TEST_DIR/module-cache"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macosx13.0 \
  -module-cache-path "$TEST_DIR/module-cache" \
  -framework AppKit -framework Network \
  "$PROJECT_DIR/App/NetworkDiscovery.swift" \
  "$PROJECT_DIR/App/VNCDiscoveryController.swift" \
  "$PROJECT_DIR/tests/discovery_ui_harness.swift" \
  -o "$TEST_DIR/discovery-ui-harness"

# Never leave an old passing result behind after an unavailable or failed run.
rm -f "$REPORT"
exec "$TEST_DIR/discovery-ui-harness" "$REPORT"
