#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$PROJECT_DIR/../work/browser-tests"
APP_DIR="$TEST_DIR/fixtures.noindex/BrowserHarness.app"
mkdir -p "$TEST_DIR/module-cache" "$APP_DIR/Contents/MacOS"
xcrun swiftc -O -D BROWSER_HARNESS -swift-version 5 -target arm64-apple-macosx13.0 \
  -module-cache-path "$TEST_DIR/module-cache" -framework AppKit -framework WebKit \
  "$PROJECT_DIR/App/BrowserStore.swift" "$PROJECT_DIR/App/BrowserPane.swift" \
  "$PROJECT_DIR/tests/browser_harness.swift" -o "$APP_DIR/Contents/MacOS/BrowserHarness"
python3 - "$APP_DIR" "$PROJECT_DIR" <<'PY'
import plistlib, sys
from pathlib import Path
app, project = map(Path,sys.argv[1:])
info = plistlib.loads((project/'App/Info.plist').read_bytes())
info.update(CFBundleExecutable='BrowserHarness',CFBundleIdentifier='local.lantern.browser-tests',CFBundleName='BrowserHarness')
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY
codesign --force --sign - --identifier local.lantern.browser-tests "$APP_DIR"
python3 - "$APP_DIR/Contents/MacOS/BrowserHarness" "$TEST_DIR" "$PROJECT_DIR" <<'PY'
from pathlib import Path
import json,subprocess,sys,time
binary,work,project=map(Path,sys.argv[1:])
report=work/'browser-report.json'
info=work/'http-fixture.json'
report.unlink(missing_ok=True)
info.unlink(missing_ok=True)
events=work/'http-fixture.jsonl'
events.unlink(missing_ok=True)
server=subprocess.Popen([sys.executable,str(project/'tests/mock_browser.py'),'--port','0','--info',str(info),'--events',str(events)])
try:
    deadline=time.monotonic()+5
    while not info.exists() and server.poll() is None and time.monotonic()<deadline: time.sleep(.02)
    if not info.exists():
        if server.poll()==77:
            print('NOT RUN: this environment blocks owned loopback HTTP listeners (exit77).');sys.exit(77)
        raise RuntimeError('Owned HTTP fixture did not start')
    result=subprocess.run([str(binary),json.loads(info.read_text())['url'],str(report),str(events)],timeout=120)
    sys.exit(result.returncode)
finally:
    if server.poll() is None: server.terminate()
    try: server.wait(timeout=5)
    except subprocess.TimeoutExpired: server.kill();server.wait()
PY
