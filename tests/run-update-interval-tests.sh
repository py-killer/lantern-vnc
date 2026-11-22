#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
PROJECT_DIR="$PWD"
TEST_DIR="${PACING_TEST_DIR:-$PROJECT_DIR/../work/update-interval-tests}"
LIBVNC_BUILD="${LIBVNC_BUILD:-$PROJECT_DIR/build/vnc}"
JPEG_BUILD="${JPEG_BUILD:-$PROJECT_DIR/build/jpeg}"
VNC_ARCHIVE="${VNC_ARCHIVE:-$LIBVNC_BUILD/libvncclient.a}"
JPEG_ARCHIVE="${JPEG_ARCHIVE:-$JPEG_BUILD/libjpeg.a}"
mkdir -p "$TEST_DIR"
SANITIZER_FLAGS=()
if [ "${TEST_SANITIZE:-0}" = 1 ]; then SANITIZER_FLAGS=(-fsanitize=address -fno-omit-frame-pointer); fi
for TEST_NAME in test_update_pacing test_update_interval; do
    SOURCES=("tests/$TEST_NAME.c")
    if [ "$TEST_NAME" = test_update_interval ]; then SOURCES+=(native/VNCBridge.c); fi
    "${CC:-clang}" -std=c11 -D_DARWIN_C_SOURCE -g -O1 -Wall -Wextra \
        ${SANITIZER_FLAGS[@]+"${SANITIZER_FLAGS[@]}"} \
        -I native -I vendor/libvncserver/include -I "$LIBVNC_BUILD/include" -I "$JPEG_BUILD" \
        "${SOURCES[@]}" "$VNC_ARCHIVE" "$JPEG_ARCHIVE" -lz -lpthread -o "$TEST_DIR/$TEST_NAME"
done
"$TEST_DIR/test_update_pacing"
python3 - "$PROJECT_DIR" "$TEST_DIR" <<'PY'
import json
from pathlib import Path
import subprocess
import sys
import time

project, work = map(Path, sys.argv[1:])
reports = []
for scenario in ('pacing-active', 'pacing-background', 'pacing-promote', 'pacing-cancel', 'pacing-input', 'pacing-reset', 'pacing-isolation'):
    info, events = work / (scenario + '.json'), work / (scenario + '.jsonl')
    info.unlink(missing_ok=True)
    events.unlink(missing_ok=True)
    server = subprocess.Popen([sys.executable, project / 'tests/mock_vnc.py', '--port', '0',
                               '--scenario', 'pacing', '--info', info, '--events', events],
                              stdout=subprocess.DEVNULL)
    try:
        for _ in range(100):
            if info.exists(): break
            if server.poll() is not None: raise RuntimeError('Mock exited')
            time.sleep(.02)
        port = json.loads(info.read_text())['port']
        process = subprocess.run([work / 'test_update_interval', str(port), scenario],
                                 check=True, capture_output=True, text=True, timeout=15)
        report = json.loads(process.stdout)
        time.sleep(.05)
        records = [json.loads(line) for line in events.read_text().splitlines()]
        requests = [r for r in records if r['event'] == 'update-request']
        inputs = [r for r in records if r['event'] in ('key', 'pointer', 'clipboard')]
        active_connection = 2 if scenario in ('pacing-reset', 'pacing-isolation') else 1
        if scenario in ('pacing-active', 'pacing-promote', 'pacing-input', 'pacing-reset', 'pacing-isolation'):
            actual = []
            for r in inputs:
                if r['connection'] != active_connection: continue
                if r['event'] == 'key': actual.append(('key', r['key'], r['down']))
                elif r['event'] == 'pointer': actual.append(('pointer', r['x'], r['y'], r['mask']))
                else: actual.append(('clipboard', r['text']))
            assert actual == [('key', 112, 1), ('key', 112, 0),
                              ('pointer', 1, 1, 1), ('pointer', 2, 1, 1),
                              ('pointer', 2, 1, 0), ('pointer', 3, 1, 0),
                              ('clipboard', 'Pacing clipboard')], (scenario, actual)
        for r in records:
            if r['event'] == 'encodings':
                assert r['values'][:8] == [7, 16, 1, 5, 6, 4, 2, 0], r
                assert [v for v in r['values'] if -256 <= v <= -247] == [-253], r
                assert [v for v in r['values'] if -32 <= v <= -23] == [-24], r
        assert all((r['x'], r['y'], r['width'], r['height']) == (0, 0, 4, 3) for r in requests), requests
        assert not any(r['event'] == 'key' and r['key'] == 120 for r in inputs), inputs
        assert report['stopMilliseconds'] < 500, report
        if scenario == 'pacing-background':
            assert len(requests) == 2 and not inputs, records
            interval = requests[1]['at'] - requests[0]['at']
            assert 1.95 <= interval < 2.4, requests
            report['requestIntervalMilliseconds'] = interval * 1000
        elif scenario == 'pacing-cancel':
            assert len(requests) == 1 and not inputs, records
        elif scenario == 'pacing-promote':
            full = [r for r in requests[1:] if not r['incremental']]
            assert full and 0 <= full[0]['at'] - report['promoted'] < .5, records
            assert len(requests) >= 5, records
            assert any(r['event'] == 'key' and r['key'] == 112 for r in inputs), inputs
            report['promotionFullRequestMilliseconds'] = (full[0]['at'] - report['promoted']) * 1000
        elif scenario == 'pacing-input':
            assert len(requests) == 1, requests
            assert inputs and max(r.get('at', report['inputAt']) for r in inputs) - report['inputAt'] < .3, inputs
            report['inputDeliveredMilliseconds'] = (max(r.get('at', report['inputAt']) for r in inputs) - report['inputAt']) * 1000
        elif scenario in ('pacing-reset', 'pacing-isolation'):
            assert len([r for r in requests if r['connection'] == 1]) == 1, requests
            assert len([r for r in requests if r['connection'] == 2]) >= 7, requests
        else:
            assert len(requests) >= 7 and not requests[0]['incremental'], requests
            assert all(r['incremental'] for r in requests[1:]), requests
        report['requests'] = len(requests)
        reports.append(report)
        print('PASS: ' + json.dumps(report, sort_keys=True))
    finally:
        server.terminate()
        server.wait(timeout=5)
(work / 'report.json').write_text(json.dumps(reports, indent=2, sort_keys=True) + '\n')
print('All update interval integration tests passed.')
PY
