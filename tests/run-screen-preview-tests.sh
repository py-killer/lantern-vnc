#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="$(cd "$PROJECT_DIR/.." && pwd)/work/screen-card-tests"
mkdir -p "$WORK_DIR/module-cache"
FLAGS=(-O)
if [[ "${SCREEN_PREVIEW_SANITIZE:-0}" == 1 ]]; then FLAGS+=(-sanitize=address); fi
xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 \
  -module-cache-path "$WORK_DIR/module-cache" "${FLAGS[@]}" \
  -framework AppKit -framework CoreGraphics "$PROJECT_DIR/App/ScreenCards.swift" \
  "$PROJECT_DIR/tests/test_screen_preview.swift" -o "$WORK_DIR/test-screen-preview"
exec "$WORK_DIR/test-screen-preview"
