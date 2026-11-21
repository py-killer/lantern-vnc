# Preview 5 validation — 21 November 2026

Candidate: 1.1.0, Preview 5, build 7. Apple M5; macOS 26.6; generated desktops and test-owned loopback servers. Real credentials and personal desktop data are not part of this evidence.

## Screen updates and correctness

- Pure frame-store checks passed: 3,834 normal and 3,674 AddressSanitizer checks, with 450 seeded dirty updates and 600 concurrent updates. Counts vary with concurrent snapshot scheduling. Covered three independent texture histories, coalescing, stale slots, padded rows, clipped/invalid rectangles, immutable packed snapshots, direct synchronous uploads, generation changes, failed uploads, clear and resize.
- 102 native Metal checks passed, including 35 full-pixel texture readbacks across all three GPU slots. Every changed and unchanged BGRA byte matched the reference image. Covered disjoint/overlapping patches, last-row/column pixels, 30 coalesced callbacks, 18 rapid submissions with busy slots, same-size reconnect and three resizes.
- Twelve steady 3×2-pixel updates uploaded exactly 288 bytes in total (24 bytes per update). Pan/zoom redraws uploaded zero new pixels.
- Existing regression coverage passed: 378 deterministic viewport checks, 622 native Metal readback/input-routing checks (including 5K edges, aspect ratio, native scrollbars and 40 resize iterations), 3,550 native controller/layout/preference checks, and 106 connection-setting checks. Independent mock servers confirmed three valid authentications and one rejected attempt. These use temporary preferences and fake credential storage.

## Local copy benchmark

The 5120×2880 BGRA image occupies 58,982,400 bytes. The previous receive path copied it for every update, even a small changed area. The new path copies only changed rows into one owned canonical image and synchronously uploads each available texture's accumulated damage. It does not pack an extra temporary image on the production path. New/resized or stale textures still require full initialization or a larger bounding union.

For 24 fixed-region steady-state updates after initialization and three-slot warm-up:

| Workload | Previous full-snapshot bytes | New CPU ingestion bytes | Extra packed-copy bytes |
| --- | ---: | ---: | ---: |
| Full image | 1,415,577,600 | 1,415,577,600 | 0 |
| 32×32 pixels | 1,415,577,600 | 98,304 | 0 |
| 256×64 pixels | 1,415,577,600 | 1,572,864 | 0 |

In this local run, the full-image baseline took 47.043 ms and direct ingestion/callback took 46.682 ms across 24 iterations. This confirms removal of an extra copy rather than a full-screen speed guarantee. The CPU benchmark's callback samples a borrowed pointer; its eligible upload-byte counts are **not measured GPU traffic**. The separate native GPU test verifies actual texture uploads and pixels. Timings exclude initialization and are not Wi-Fi, JPEG-decode, frame-rate or live input-latency measurements.

## Input during slow transfers

- 115 protocol sessions passed with AddressSanitizer on the bridge, test harness, and all LibVNCClient C, including the modified reader. The unchanged libjpeg-turbo dependency used its Release SIMD build. No sanitizer findings.
- 100 test-client hook registration/default-off/validation/cleanup cases passed.
- Test servers withheld the rest of a screen or capability update for about 900 ms. Pointer/button/key input deliberately queued after 150 ms reached the server in correct order before payload release, in buffered and large reads. Final input preceded release by at least 745 ms in recorded cases. This is fixture timing from the server's partial-start timestamp, **not** a per-command enqueue measurement or a live Wi-Fi benchmark.
- Verified button press/release coordinates survive motion coalescing, view-only suppression/toggling, cancellation, dropped payloads and 100 extra wakeups during a held update without premature read timeout.
- Existing Tight-first encoding order, compression presets and JPEG quality levels were asserted unchanged. Actual Tight JPEG decoding, CopyRect, resize, authentication, clipboard, failed connection and malformed/oversized frame cases also passed.

## Scope and remaining limits

Picture presets, JPEG quality, server resolution and Fit/zoom behavior are unchanged by these optimizations. Changed-region CPU/GPU work reduces local overhead; it does not claim to reduce already-negotiated network traffic. Input servicing remains on the connection's existing worker, with no concurrent access to the protocol client. Long CPU decode operations and server/network latency can still delay visible responses.

Physical external-display transitions, the full manual hardware matrix, Developer ID signing and notarization remain pending. This remains an ad hoc signed preview. Live-server validation of this build is recorded separately once performed.
