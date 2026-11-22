#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$PROJECT_DIR/../work/workspace-tests"
APP_DIR="$TEST_DIR/fixtures.noindex/WorkspaceHarness.app"
mkdir -p "$TEST_DIR/module-cache" "$APP_DIR/Contents/MacOS"
xcrun swiftc -O -D APP_UI_HARNESS -D BROWSER_HARNESS -D LANTERN_TESTING \
  -swift-version 5 -target arm64-apple-macosx13.0 -module-cache-path "$TEST_DIR/module-cache" \
  -import-objc-header "$PROJECT_DIR/native/VNCBridge.h" \
  -framework AppKit -framework Metal -framework MetalKit -framework QuartzCore \
  -framework Network -framework Security -framework WebKit \
  "$PROJECT_DIR"/App/*.swift "$PROJECT_DIR/tests/workspace_harness.swift" \
  "$PROJECT_DIR/build/VNCBridge.o" "$PROJECT_DIR/build/vnc/libvncclient.a" \
  "$PROJECT_DIR/build/jpeg/libjpeg.a" -lz -o "$APP_DIR/Contents/MacOS/WorkspaceHarness"
python3 - "$APP_DIR" "$PROJECT_DIR" <<'PY'
import plistlib, sys
from pathlib import Path
app, project = map(Path, sys.argv[1:])
info = plistlib.loads((project / 'App/Info.plist').read_bytes())
info.update(CFBundleExecutable='WorkspaceHarness', CFBundleIdentifier='local.lantern.workspace-tests', CFBundleName='WorkspaceHarness')
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY
codesign --force --sign - --identifier local.lantern.workspace-tests "$APP_DIR"
python3 - "$PROJECT_DIR" "$TEST_DIR" "$APP_DIR/Contents/MacOS/WorkspaceHarness" <<'PY'
import json
from pathlib import Path
import socket
import subprocess
import sys
import time

project, work, binary = map(Path, sys.argv[1:])
try:
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
except PermissionError:
    print('NOT RUN: environment blocks owned loopback listeners (exit 77); workspace integration did not pass.')
    sys.exit(77)
servers = []
try:
    endpoints = []
    for name, script, arguments in (
        ('vnc-a', 'mock_vnc.py', ['--scenario', 'pacing']),
        ('vnc-b', 'mock_vnc.py', ['--scenario', 'pacing']),
        ('browser', 'mock_browser.py', []),
    ):
        info, events = work / (name + '.json'), work / (name + '.jsonl')
        info.unlink(missing_ok=True); events.unlink(missing_ok=True)
        server = subprocess.Popen([sys.executable, str(project / 'tests' / script), '--port', '0',
            '--info', str(info), '--events', str(events), *arguments], stdout=subprocess.DEVNULL)
        servers.append(server)
        limit = time.monotonic() + 5
        while not info.exists() and server.poll() is None and time.monotonic() < limit:
            time.sleep(.02)
        if not info.exists():
            raise RuntimeError('Owned fixture did not start: ' + name)
        endpoints.append(json.loads(info.read_text()))
    report = work / 'workspace-report.json'
    report.unlink(missing_ok=True)
    result = subprocess.run([str(binary), str(endpoints[0]['port']), str(endpoints[1]['port']), endpoints[2]['url'],
        str(work / 'vnc-a.jsonl'), str(work / 'vnc-b.jsonl'), str(report)], timeout=150)
    if result.returncode:
        sys.exit(result.returncode)
    for name, key in (('vnc-a', 97), ('vnc-b', 98)):
        events = [json.loads(line) for line in (work / (name + '.jsonl')).read_text().splitlines()]
        assert sum(e['event'] == 'pixel-format' for e in events) == 1, name
        assert sum(e['event'] == 'key' and e['key'] == key for e in events) == 2, name
        assert not any(e['event'] == 'key' and e['key'] in (118, 120) for e in events), name
        assert sum(e['event'] == 'closed' for e in events) == 1, name
    print('PASS: independent server transcripts confirm exactly two sessions, target-specific input and complete cleanup.')
finally:
    for server in servers:
        if server.poll() is None:
            server.terminate()
        try:
            server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server.kill(); server.wait()
PY
