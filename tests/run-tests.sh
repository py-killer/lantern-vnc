#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
PROJECT_DIR="$PWD"
TEST_DIR="$PROJECT_DIR/../work/native-tests"
mkdir -p "$TEST_DIR"
LIBVNC_BUILD="${LIBVNC_BUILD:-$PROJECT_DIR/build/vnc}"
JPEG_BUILD="${JPEG_BUILD:-$PROJECT_DIR/build/jpeg}"
LIBVNC_SOURCE="$PROJECT_DIR/vendor/libvncserver"
VNC_ARCHIVE="${VNC_ARCHIVE:-$LIBVNC_BUILD/libvncclient.a}"
JPEG_ARCHIVE="${JPEG_ARCHIVE:-$JPEG_BUILD/libjpeg.a}"
CC="${CC:-clang}"
SANITIZER_FLAGS=()
if [ "${TEST_SANITIZE:-0}" = 1 ]; then
    SANITIZER_FLAGS=(-fsanitize=address -fno-omit-frame-pointer)
fi
"$CC" -std=c11 -D_DARWIN_C_SOURCE -g -O1 -Wall -Wextra \
    "${SANITIZER_FLAGS[@]}" \
    -I "$PROJECT_DIR/native" -I "$LIBVNC_SOURCE/include" \
    -I "$LIBVNC_BUILD/include" -I "$JPEG_BUILD" \
    "$PROJECT_DIR/tests/test_client.c" "$PROJECT_DIR/native/VNCBridge.c" \
    "$VNC_ARCHIVE" "$JPEG_ARCHIVE" -lz -lpthread \
    -o "$TEST_DIR/test-client"

python3 - "$PROJECT_DIR" "$TEST_DIR" <<'PY'
import json
from pathlib import Path
import socket
import subprocess
import sys
import time

project, work = map(Path, sys.argv[1:])
for scenario in ('frames', 'tight', 'password', 'view-only', 'auth-fail', 'stall', 'oversize', 'drop'):
    info = work / (scenario + '.json')
    events = work / (scenario + '.jsonl')
    info.unlink(missing_ok=True)
    events.unlink(missing_ok=True)
    server_scenario = 'frames' if scenario == 'view-only' else scenario
    server = subprocess.Popen([sys.executable, str(project / 'tests/mock_vnc.py'),
                               '--port', '0', '--scenario', server_scenario,
                               '--info', str(info), '--events', str(events)],
                              stdout=subprocess.DEVNULL)
    try:
        for _ in range(100):
            if info.exists():
                break
            if server.poll() is not None:
                raise RuntimeError('Mock server exited')
            time.sleep(.02)
        port = json.loads(info.read_text())['port']
        subprocess.run([str(work / 'test-client'), str(port), scenario], check=True, timeout=45)
        time.sleep(.05)
        records = [json.loads(line) for line in events.read_text().splitlines()]
        inputs = [item for item in records if item['event'] in ('key', 'pointer', 'clipboard')]
        if scenario == 'frames':
            for connection in range(1, 6):
                current = [item for item in inputs if item['connection'] == connection]
                assert any(item['event'] == 'key' and item['key'] == 97 and item['down'] for item in current), current
                assert any(item['event'] == 'key' and item['key'] == 97 and not item['down'] for item in current), current
                assert any(item['event'] == 'pointer' and (item['x'], item['y'], item['mask']) == (2, 1, 1) for item in current), current
                assert any(item['event'] == 'clipboard' and item['text'] == 'Local clipboard' for item in current), current
            print('PASS: actual keyboard, pointer, and clipboard protocol messages')
        elif scenario == 'view-only':
            assert not inputs, inputs
            print('PASS: view-only mode blocks every input message')
        elif scenario == 'password':
            assert len([item for item in records if item['event'] == 'password-verified']) == 5
            print('PASS: classic VNC password DES response verified with CommonCrypto')
    finally:
        server.terminate()
        server.wait(timeout=5)
with socket.socket() as probe:
    probe.bind(('127.0.0.1', 0))
    unavailable_port = probe.getsockname()[1]
subprocess.run([str(work / 'test-client'), str(unavailable_port), 'connect-fail'], check=True, timeout=20)
print('All native integration tests passed.')
PY
