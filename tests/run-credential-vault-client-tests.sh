#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$PROJECT_DIR/../work/vault-client-tests"
mkdir -p "$TEST_DIR/module-cache"
xcrun swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macosx13.0 \
  -module-cache-path "$TEST_DIR/module-cache" -framework Foundation -framework Security \
  "$PROJECT_DIR/App/PasswordStore.swift" "$PROJECT_DIR/App/VaultProtocol.swift" "$PROJECT_DIR/App/VaultV2Protocol.swift" \
  "$PROJECT_DIR/App/CredentialVaultClient.swift" "$PROJECT_DIR/tests/test_credential_vault_client.swift" \
  -o "$TEST_DIR/VaultClientTests"
"$TEST_DIR/VaultClientTests"
