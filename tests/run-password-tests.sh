#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$PROJECT_DIR/../work/password-store-tests"
mkdir -p "$TEST_DIR/module-cache"
xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 \
  -module-cache-path "$TEST_DIR/module-cache" -framework Security \
  "$PROJECT_DIR/App/PasswordStore.swift" "$PROJECT_DIR/tests/test_password_store.swift" \
  -o "$TEST_DIR/test-password-store"
codesign --force --sign - --identifier local.lantern.vnc.password-tests "$TEST_DIR/test-password-store"
# Unique test services, synthetic values, process-local interaction disabled.
# Exit 77 means Keychain access was unavailable, never a passing integration test.
"$TEST_DIR/test-password-store"
