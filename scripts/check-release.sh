#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$PROJECT_DIR/../work/release-checks"
mode="${1:---full}"
if [[ "$mode" != --full && "$mode" != --headless ]]; then
  echo 'Usage: ./scripts/check-release.sh [--full|--headless]' >&2
  exit 2
fi
mkdir -p "$TEST_DIR/module-cache"
"$PROJECT_DIR/scripts/build-app.sh"
xcrun swiftc -swift-version 5 -module-cache-path "$TEST_DIR/module-cache" \
  "$PROJECT_DIR/App/DeviceStore.swift" "$PROJECT_DIR/tests/test_device_store.swift" \
  -o "$TEST_DIR/test-devices"
"$PROJECT_DIR/tests/run-connection-preferences-tests.sh"
"$PROJECT_DIR/tests/run-network-latency-tests.sh"
"$PROJECT_DIR/tests/run-browser-store-tests.sh"
"$PROJECT_DIR/tests/run-screen-preview-tests.sh"
"$PROJECT_DIR/tests/run-window-placement-tests.sh" --geometry-only
"$PROJECT_DIR/tests/run-frame-update-tests.sh"
"$PROJECT_DIR/tests/run-network-discovery-tests.sh"
if "$PROJECT_DIR/tests/run-password-tests.sh"; then
  echo 'PASS: isolated macOS Keychain checks.'
else
  keychain_result=$?
  if [[ "$mode" == --headless && "$keychain_result" == 77 ]]; then
    echo 'UNAVAILABLE: this headless environment cannot exercise the real Keychain; local release checks are still required.'
  else
    exit "$keychain_result"
  fi
fi
"$TEST_DIR/test-devices"
if [[ "$mode" == --full ]]; then
  "$PROJECT_DIR/tests/run-window-placement-tests.sh"
  "$PROJECT_DIR/tests/run-display-tests.sh"
  "$PROJECT_DIR/tests/run-performance-display-tests.sh"
  "$PROJECT_DIR/tests/run-screen-cards-tests.sh"
  "$PROJECT_DIR/tests/run-browser-tests.sh"
  "$PROJECT_DIR/tests/run-workspace-tests.sh"
  "$PROJECT_DIR/tests/run-app-ui-tests.sh"
  "$PROJECT_DIR/tests/run-connection-settings-tests.sh"
  "$PROJECT_DIR/tests/run-discovery-ui-tests.sh"
else
  xcrun swiftc -swift-version 5 -O -module-cache-path "$TEST_DIR/module-cache" \
    "$PROJECT_DIR/App/DesktopViewport.swift" "$PROJECT_DIR/tests/test_viewport.swift" \
    -o "$TEST_DIR/test-viewport"
  "$TEST_DIR/test-viewport"
  echo 'NOT RUN: native Metal/window tests. Headless checks do not approve a release.'
fi
TEST_SANITIZE=1 "$PROJECT_DIR/tests/run-tests.sh"
TEST_SANITIZE=1 "$PROJECT_DIR/tests/run-update-interval-tests.sh"
codesign --verify --deep --strict "$PROJECT_DIR/build/artifacts.noindex/Lantern VNC.app"
echo 'Automated checks completed. Record manual display/hardware results in docs/RELEASE_CHECKLIST.md before a stable release.'
