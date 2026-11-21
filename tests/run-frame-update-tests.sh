#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Pure Swift correctness checks and an owned framebuffer-copy benchmark.
# Does not use Metal, AppKit windows, network connections, or Keychain.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="$(cd "$PROJECT_DIR/.." && pwd)/work"
TEST_DIR="$WORK_DIR/frame-update-tests"

if [[ "$(uname -s)" != Darwin ]]; then
  echo "Frame-update tests require macOS and the Xcode command-line tools." >&2
  exit 1
fi
if ! command -v xcrun >/dev/null 2>&1 || ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Swift compiler unavailable. Install or select the Xcode command-line tools." >&2
  exit 1
fi

COMPILER_FLAGS=(-O)
case "${FRAME_TEST_SANITIZE:-0}" in
  0) REPORT_FILE="$TEST_DIR/frame-update-report.json" ;;
  1) COMPILER_FLAGS+=(-sanitize=address)
     REPORT_FILE="$TEST_DIR/frame-update-report-asan.json" ;;
  *) echo "FRAME_TEST_SANITIZE must be 0 or 1." >&2; exit 1 ;;
esac
# The harness records this flag so instrumented timings are not mistaken for
# the normal optimized benchmark. Sanitizer reports also use a separate path.
export FRAME_TEST_SANITIZE="${FRAME_TEST_SANITIZE:-0}"

mkdir -p "$TEST_DIR/module-cache"
rm -f "$REPORT_FILE"
xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 \
  -module-cache-path "$TEST_DIR/module-cache" \
  "${COMPILER_FLAGS[@]}" \
  "$PROJECT_DIR/App/FrameUpdateStore.swift" \
  "$PROJECT_DIR/tests/test_frame_update_store.swift" \
  -o "$TEST_DIR/test-frame-updates"

exec "$TEST_DIR/test-frame-updates" "$REPORT_FILE"
