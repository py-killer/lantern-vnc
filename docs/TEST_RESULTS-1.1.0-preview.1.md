# 1.1.0-preview.1 verification

Candidate status: **preview, not a stable release**. Recorded on 20 November 2026.

## Automated results

| Check | Result | What it establishes |
| --- | --- | --- |
| Viewport geometry | 378 checks passed | Fit/aspect ratio, readable Auto policy, pixel scaling, pan limits, anchor preservation, hit coordinates, and simulated backing scales. |
| Native Metal and input harness | 622 checks passed | Actual GPU output and local input routing in an owned offscreen window on Apple M5, macOS 26.6 (25G72), backing scale 2. |
| App controller UI | 3,238 assertions passed | Four real-controller window layouts, toolbar/scroller clipping, sidebar restoration, zoom actions, Hand/Esc updates and preference isolation. No network or global input. |
| VNC protocol regression with AddressSanitizer | 45 sessions passed | Tight/Raw/CopyRect decoding, resize, independent VNC password challenge, keyboard/pointer/clipboard messages, view-only suppression, failure/cancel/reconnect cleanup. |
| Saved device store | Passed | Three-device capacity, migration, rename/deduplication, persistence and credential-free saved schema. |

The native display harness used generated frames, not a personal desktop. It verified 5120 × 2880 frames at 860 × 540 and 1180 × 760 window sizes, all four pan corners and pointer coordinates, native horizontal/vertical scroller actions, the final row/column/pixel, one-pixel stripe rendering, pinch anchoring, Hand navigation in view-only mode, normal remote scrolling, and 40 non-square resize cases. Other native frames included 1600 × 1200 and 5120 × 1440.

The tested renderer source hashes are:

```text
MetalDesktop.swift  b33544e051d537358eaf6007d5b2d43f8f23ece859847463886343e5ad745dd8
DesktopViewport.swift  132a2d095ad2cc72d3aeb238c14716b12df678e16157bba0804fec45b860507d
```

[Machine-readable controller report](release-evidence/1.1.0-preview.1/app-ui-report.json) · [Machine-readable native report](release-evidence/1.1.0-preview.1/native-display-report.json) · [5K bottom-right edge capture](release-evidence/1.1.0-preview.1/5k-actual-bottom-right.png) · [Final resize capture](release-evidence/1.1.0-preview.1/5k-resize-stress-final.png)

## Verification limits

These are synthetic native and protocol tests on one Mac/GPU/display backing configuration. They do not replace a real TightVNC desktop check or the manual hardware matrix. Physical external-display transitions between 1× and 2×, monitor disconnect/reconnect, macOS panel scaling changes, and other hardware/OS combinations remain **not run**. The release checklist remains open for those cases. No performance benchmark, frame-rate guarantee, or general hardware certification is implied.

Missing Metal/WindowServer access is reported by the native harness with exit 77; it is never recorded as a pass. CI headless checks explicitly omit native GPU/hardware approval.

Run `./scripts/check-release.sh --full` on a Mac with Metal/WindowServer access and record the remaining results in [the release checklist](RELEASE_CHECKLIST.md) before marking a stable release.
