#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
TEST_DIR="$PROJECT_DIR/../work/credential-io-tests"
mkdir -p "$TEST_DIR/module-cache"
xcrun swiftc -O -D APP_UI_HARNESS -swift-version 5 -target arm64-apple-macosx13.0 \
  -module-cache-path "$TEST_DIR/module-cache" -import-objc-header "$PROJECT_DIR/native/VNCBridge.h" \
  -framework AppKit -framework Metal -framework MetalKit -framework QuartzCore -framework Network -framework Security -framework WebKit \
  "$PROJECT_DIR"/App/*.swift "$PROJECT_DIR/tests/credential_io_harness.swift" \
  "$BUILD_DIR/VNCBridge.o" "$BUILD_DIR/vnc/libvncclient.a" "$BUILD_DIR/jpeg/libjpeg.a" -lz \
  -o "$TEST_DIR/credential-io-harness"
python3 - "$PROJECT_DIR" "$TEST_DIR" <<'PY'
import json, subprocess, sys, time
from pathlib import Path
project, work = map(Path, sys.argv[1:])
info, events, report = [work/name for name in ('server.json','events.jsonl','credential-io-report.json')]
for path in (info, events, report): path.unlink(missing_ok=True)
server = subprocess.Popen([sys.executable,str(project/'tests/mock_vnc.py'),'--port','0',
    '--scenario','password','--info',str(info),'--events',str(events)], stdout=subprocess.DEVNULL)
try:
    deadline=time.monotonic()+5
    while not info.exists() and server.poll() is None and time.monotonic()<deadline: time.sleep(.02)
    if not info.exists():
        if server.poll()==77:
            print('NOT RUN: owned loopback listener unavailable (exit77).');sys.exit(77)
        raise RuntimeError('Owned VNC fixture failed to start')
    result=subprocess.run([str(work/'credential-io-harness'),str(json.loads(info.read_text())['port']),str(report)],timeout=120)
    if result.returncode: sys.exit(result.returncode)
    journal=[json.loads(line) for line in events.read_text().splitlines()]
    assert sum(row['event']=='password-verified' for row in journal)==9, 'Expected nine owned authentications (queued Save/Forget, queued Forget/Save, forget/save/restart/isolation A+B/delete/ambiguous)'
    print('PASS: independent server verified all nine synthetic password authentications; no canceled read created a session.')
finally:
    if server.poll() is None: server.terminate()
    try: server.wait(timeout=5)
    except subprocess.TimeoutExpired: server.kill();server.wait()
PY
