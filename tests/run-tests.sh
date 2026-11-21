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
    ${SANITIZER_FLAGS[@]+"${SANITIZER_FLAGS[@]}"} \
    -I "$PROJECT_DIR/native" -I "$LIBVNC_SOURCE/include" \
    -I "$LIBVNC_BUILD/include" -I "$JPEG_BUILD" \
    "$PROJECT_DIR/tests/test_client.c" "$PROJECT_DIR/native/VNCBridge.c" \
    "$VNC_ARCHIVE" "$JPEG_ARCHIVE" -lz -lpthread \
    -o "$TEST_DIR/test-client"
"$TEST_DIR/test-client" --read-wake-registration
"$CC" -std=c11 -D_DARWIN_C_SOURCE -g -O1 -Wall -Wextra \
    ${SANITIZER_FLAGS[@]+"${SANITIZER_FLAGS[@]}"} \
    -I "$PROJECT_DIR/native" -I "$LIBVNC_SOURCE/include" \
    -I "$LIBVNC_BUILD/include" -I "$JPEG_BUILD" \
    "$PROJECT_DIR/tests/test_network_rtt.c" \
    "$VNC_ARCHIVE" "$JPEG_ARCHIVE" -lz -lpthread \
    -o "$TEST_DIR/test-network-rtt"
"$TEST_DIR/test-network-rtt"

python3 - "$PROJECT_DIR" "$TEST_DIR" <<'PY'
import json
from pathlib import Path
import socket
import subprocess
import sys
import time

project, work = map(Path, sys.argv[1:])
# scenario, mock scenario, requested Tight JPEG level (-1 disables it), compression.
cases = (
    ('frames', 'frames', -1, 1),
    ('tight', 'tight', -1, 1),
    ('jpeg', 'jpeg', 8, 1),
    ('quality-balanced', 'frames', 8, 1),
    ('quality-wifi', 'frames', 8, 3),
    ('quality-lossless', 'tight', -1, 3),
    ('compression-min', 'frames', 8, 0),
    ('compression-max', 'frames', 8, 9),
    ('password', 'password', -1, 1),
    ('view-only', 'frames', -1, 1),
    ('auth-fail', 'auth-fail', -1, 1),
    ('stall', 'stall', -1, 1),
    ('oversize', 'oversize', -1, 1),
    ('drop', 'drop', -1, 1),
    ('slow-small', 'slow-small', -1, 1),
    ('slow-large', 'slow-large', -1, 1),
    ('slow-capabilities', 'slow-capabilities', -1, 1),
    ('slow-view-only', 'slow-view-only', -1, 1),
    ('slow-toggle-view', 'slow-small', -1, 1),
    ('slow-wake-storm', 'slow-small', -1, 1),
    ('slow-cancel', 'slow-cancel', -1, 1),
    ('slow-drop', 'slow-drop', -1, 1),
    ('rtt-idle', 'rtt-idle', -1, 1),
)
for scenario, server_scenario, quality, compression in cases:
    info = work / (scenario + '.json')
    events = work / (scenario + '.jsonl')
    info.unlink(missing_ok=True)
    events.unlink(missing_ok=True)
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
        negotiated = [item for item in records if item['event'] == 'encodings']
        assert len(negotiated) == (0 if scenario in ('auth-fail', 'stall') else 1 if scenario == 'rtt-idle' else 5), negotiated
        for item in negotiated:
            encodings = item['values']
            # Preserve Tight-first preference and its lossless alternatives.
            assert encodings[:8] == [7, 16, 1, 5, 6, 4, 2, 0], encodings
            assert [value for value in encodings if -256 <= value <= -247] == [compression - 256], encodings
            assert [value for value in encodings if -32 <= value <= -23] == ([] if quality < 0 else [quality - 32]), encodings
        if negotiated:
            print('PASS: %s negotiated compression %s, JPEG %s, unchanged encoding preference' %
                  (scenario, compression, 'off' if quality < 0 else 'level %s' % quality))
        if scenario == 'jpeg':
            sent = [item for item in records if item['event'] == 'jpeg-sent']
            assert len(sent) == 5 and all(item['width'] == 4 and item['height'] == 3 for item in sent), sent
            print('PASS: actual Tight JPEG decode, BGRX channels, CopyRect, and raw resize')
        inputs = [item for item in records if item['event'] in ('key', 'pointer', 'clipboard')]
        if scenario == 'rtt-idle':
            assert len(inputs) == 5, inputs
            requests = [item for item in records if item['event'] == 'update-request']
            assert len(requests) == 2, requests
            print('PASS: repeated RTT queries send no extra RFB input or framebuffer requests')
        if scenario.startswith('slow-'):
            if scenario == 'slow-view-only':
                assert not inputs, inputs
                print('PASS: view-only suppresses all queued input during a partial framebuffer')
            elif scenario != 'slow-cancel':
                expected = [('pointer', 1, 1, 1), ('pointer', 2, 1, 1), ('pointer', 2, 1, 0)]
                if scenario != 'slow-toggle-view':
                    expected.append(('pointer', 3, 1, 0))
                expected += [('key', 98, 1), ('key', 98, 0), ('pointer', 3, 1, 4), ('pointer', 3, 1, 0)]
                for connection in range(1, 6):
                    current = [item for item in records if item['connection'] == connection]
                    release = next(index for index, item in enumerate(current) if item['event'] == 'slow-update-release')
                    actual = []
                    for index, item in enumerate(current):
                        if item['event'] not in ('key', 'pointer'):
                            continue
                        assert index < release and item['during_slow'], (scenario, current)
                        if item['event'] == 'pointer':
                            actual.append(('pointer', item['x'], item['y'], item['mask']))
                        else:
                            actual.append(('key', item['key'], item['down']))
                    assert actual == expected, (scenario, actual, expected)
                print('PASS: %s ordered keys/buttons/coordinates arrived BEFORE delayed framebuffer completion' % scenario)
            else:
                print('PASS: cancellation interrupts the partial framebuffer without a completed-frame callback')
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
