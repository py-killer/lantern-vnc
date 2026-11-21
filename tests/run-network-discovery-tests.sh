#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$PROJECT_DIR/../work/network-discovery-tests"
mkdir -p "$TEST_DIR/module-cache"
xcrun swiftc -swift-version 5 -D NETWORK_DISCOVERY_TESTS -O \
  -module-cache-path "$TEST_DIR/module-cache" \
  "$PROJECT_DIR/App/NetworkDiscovery.swift" \
  "$PROJECT_DIR/tests/test_network_discovery.swift" \
  -o "$TEST_DIR/test-network-discovery"
"$TEST_DIR/test-network-discovery"
