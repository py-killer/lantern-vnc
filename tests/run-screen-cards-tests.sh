#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Owned invisible window only. No launches of a user's installed app.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="$(cd "$PROJECT_DIR/.." && pwd)/work/screen-card-tests"
mkdir -p "$WORK_DIR/module-cache"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macosx13.0 \
  -module-cache-path "$WORK_DIR/module-cache" -framework AppKit -framework CoreGraphics \
  "$PROJECT_DIR/App/ScreenCards.swift" "$PROJECT_DIR/tests/screen_cards_harness.swift" \
  -o "$WORK_DIR/test-screen-cards"
exec "$WORK_DIR/test-screen-cards" "$WORK_DIR/screen-card.png"
