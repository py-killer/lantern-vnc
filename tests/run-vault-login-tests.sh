#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-$PROJECT_DIR/.git/codex-signing/release-config.json}"
CACHE="${2:-$PROJECT_DIR/.git/codex-signing/credential-vault-v2}"
if [[ ! -f "$CONFIG" || ! -f "$CACHE/frozen-manifest.json" ]]; then
  echo 'NOT RUN: a private publisher configuration and frozen PUBLICv2 helper are required (exit77).'
  exit 77
fi
python3 "$PROJECT_DIR/tests/vault_login_lab.py" "$PROJECT_DIR" "$CONFIG" "$CACHE"
