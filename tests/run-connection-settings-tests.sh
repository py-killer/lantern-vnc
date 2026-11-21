#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
TEST_DIR="$PROJECT_DIR/../work/connection-settings-tests"
mkdir -p "$TEST_DIR/module-cache"
xcrun swiftc -O -D APP_UI_HARNESS -swift-version 5 -target arm64-apple-macosx13.0 \
  -module-cache-path "$TEST_DIR/module-cache" \
  -import-objc-header "$PROJECT_DIR/native/VNCBridge.h" \
  -framework AppKit -framework Metal -framework MetalKit -framework QuartzCore -framework Network -framework Security \
  "$PROJECT_DIR"/App/*.swift "$PROJECT_DIR/tests/connection_settings_harness.swift" \
  "$BUILD_DIR/VNCBridge.o" "$BUILD_DIR/vnc/libvncclient.a" "$BUILD_DIR/jpeg/libjpeg.a" \
  -lz -o "$TEST_DIR/connection-settings-harness"

python3 - "$PROJECT_DIR" "$TEST_DIR" <<'PY'
import json
from pathlib import Path
import socket
import subprocess
import sys
import time

project, work = map(Path, sys.argv[1:])
servers = []
report = work / 'connection-settings-report.json'
report.unlink(missing_ok=True)
try:
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
except PermissionError:
    print('NOT RUN: this environment blocks owned loopback listeners (exit 77); not a passing settings test.')
    sys.exit(77)
try:
    ports = []
    for scenario in ('password', 'auth-fail', 'stall'):
        info, events = work / (scenario + '.json'), work / (scenario + '.jsonl')
        info.unlink(missing_ok=True)
        events.unlink(missing_ok=True)
        server = subprocess.Popen([sys.executable, str(project / 'tests/mock_vnc.py'),
            '--port', '0', '--scenario', scenario, '--info', str(info), '--events', str(events)],
            stdout=subprocess.DEVNULL)
        servers.append(server)
        deadline = time.monotonic() + 5
        while not info.exists() and time.monotonic() < deadline and server.poll() is None:
            time.sleep(.02)
        if not info.exists():
            raise RuntimeError('Owned loopback mock did not start: ' + scenario)
        ports.append(str(json.loads(info.read_text())['port']))
    result = subprocess.run([str(work / 'connection-settings-harness'), *ports, str(report)], timeout=90)
    if result.returncode:
        sys.exit(result.returncode)
    good = [json.loads(line) for line in (work / 'password.jsonl').read_text().splitlines()]
    rejected = [json.loads(line) for line in (work / 'auth-fail.jsonl').read_text().splitlines()]
    assert sum(event['event'] == 'password-verified' for event in good) == 3
    assert sum(event['event'] == 'auth-response' for event in rejected) == 1
    assert not any(event['event'] == 'password-verified' for event in rejected)
    print('PASS: independent loopback server verified three password authentications and one rejected attempt.')
finally:
    for server in servers:
        if server.poll() is None:
            server.terminate()
        try:
            server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server.kill()
            server.wait()
PY
