# Preview 6 validation — 21 November 2026

Candidate: 1.1.0, Preview 6, build 8. Native arm64 build and Swift type checks passed. The installed Preview 5 remained untouched during validation.

## Measurement and meaning

The viewer displays **RTT … ms** below the connection name, using the existing one-second status timer. It reads the kernel-smoothed round-trip estimate from the current authenticated VNC TCP connection. macOS exports `tcpi_srtt` in whole **milliseconds**, so no microsecond conversion or invented decimal precision is used. Zero, missing/short/error replies, closed or pending connections produce an unavailable state, rather than a fabricated zero latency. [Apple public TCP definitions](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/netinet/tcp.h)

The public TCP API has no RTT sample timestamp. Re-reading the same estimate does not make it fresh. The idle indication appears after five seconds without an **observed transport-counter change**; its age describes observed traffic, not when the kernel sampled RTT. New traffic clears idle. Disconnect and reconnect clear the previous connection's estimate. [Apple TCP socket options](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/man/man4/tcp.4)

This is TCP round-trip time to the immediate peer, not keyboard/mouse-to-screen delay. Server capture/encoding, transfer of large updates, decoding and rendering add delay. A local SSH forwarding endpoint can have low TCP RTT despite a slow remote connection. The tooltip and Wiki explain this limit. The getter sends no ping, synthetic input, refresh or other VNC message; it does not transmit analytics or retain a measurement history.

## Targeted tests

- **78 pure Swift checks passed:** nil, zero, negative/non-finite/out-of-range estimates; integer formatting; bounded large values; unavailable and idle states; observed-traffic age wording; forwarding and input-to-screen caveats; safe age conversion.
- **4,231 native controller checks passed:** includes six latency states, a long connection title, four window shapes and both sidebar states. The complete RTT text remains readable, below the title and separate from the four toolbar controls. Header height remains 50 points. Existing Fit/zoom/sidebar and endpoint-preference coverage passed as well. Test-owned offscreen windows, generated pixels, fake credential storage and temporary preferences only.
- **125 connection-setting checks passed:** the RTT label is hidden before authentication and after cancel/rejection/disconnect, visible while connected, and reset before reconnect. Three correct authentications and one rejection were independently verified by owned loopback servers. No real user Keychain credentials were used.
- **116 protocol sessions passed with AddressSanitizer** on the modified bridge, C test harness and LibVNCClient. The unchanged JPEG dependency used its Release SIMD build. Existing input, fragmented-screen/capability reads, wake storms, view-only, cancellation, JPEG/CopyRect/resize, authentication and quality negotiation cases passed.
- Native deterministic RTT tests cover correct units, unavailable/zero/short/state/error replies, the exact idle boundary, unchanged polling, counter-change activity, reconnect reset and **8,000 concurrent getter calls**.
- The dedicated idle fixture observed a 1 ms loopback estimate and idle after 5,001 ms. Repeated queries added no wire traffic: the server recorded only the original five input messages and two framebuffer requests. This is a loopback correctness result, not a measured LAN or input-to-screen performance claim.

## Scope

No renderer, JPEG quality, encoding preference, server resolution or saved viewing preference was changed for this feature. The previous [Preview 5 validation](TEST_RESULTS-1.1.0-preview.5.md) remains historical evidence for its dirty-region/GPU optimization; those counts are not claimed as new hardware runs here.

Private owner network diagnostics are kept outside the public repository and archives. Physical external-display transitions, the full manual hardware matrix, Developer ID signing and notarization remain pending. This remains an ad hoc signed preview. Any post-installation live observation is recorded separately in the release notes.
