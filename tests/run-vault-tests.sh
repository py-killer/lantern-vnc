#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
: "${RCODESIGN:?Set RCODESIGN to the verified private rcodesign0.29.0 executable.}"
python3 "$PROJECT_DIR/tests/vault_xpc_lab.py" "$PROJECT_DIR" "$RCODESIGN"
