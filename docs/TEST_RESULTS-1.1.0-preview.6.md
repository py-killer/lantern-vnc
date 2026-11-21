# Preview 6 validation — 21 November 2026

Candidate: 1.1.0, Preview 6, build 9. Native arm64 build and Swift type checks passed. Window and no-prompt changes were validated with owned test windows and synthetic credentials before replacing the previously installed build.

## Measurement and meaning

The viewer displays **RTT … ms** below the connection name, using the existing one-second status timer. It reads the kernel-smoothed round-trip estimate from the current authenticated VNC TCP connection. macOS exports `tcpi_srtt` in whole **milliseconds**, so no microsecond conversion or invented decimal precision is used. Zero, missing/short/error replies, closed or pending connections produce an explicit `RTT unavailable` state, rather than a fabricated zero latency. [Apple public TCP definitions](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/netinet/tcp.h)

The public TCP API has no RTT sample timestamp. Re-reading the same estimate does not make it fresh. The idle indication appears after five seconds without an **observed transport-counter change**; its age describes observed traffic, not when the kernel sampled RTT. New traffic clears idle. Disconnect and reconnect clear the previous connection's estimate. [Apple TCP socket options](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/man/man4/tcp.4)

This is TCP round-trip time to the immediate peer, not keyboard/mouse-to-screen delay. Server capture/encoding, transfer of large updates, decoding and rendering add delay. A local SSH forwarding endpoint can have low TCP RTT despite a slow remote connection. The tooltip and Wiki explain this limit. The getter sends no ping, synthetic input, refresh or other VNC message; it does not transmit analytics or retain a measurement history.

## Targeted tests

- **78 pure Swift checks passed:** nil, zero, negative/non-finite/out-of-range estimates; integer formatting; bounded large values; unavailable and idle states; observed-traffic age wording; forwarding and input-to-screen caveats; safe age conversion.
- **4,183 native controller checks passed:** includes six latency states, a long connection title, four window shapes and both sidebar states. The complete RTT text remains readable, below the title and separate from the four toolbar controls. Header height remains 50 points. Existing Fit/zoom/sidebar and endpoint-preference coverage passed as well. Test-owned offscreen windows, generated pixels, fake credential storage and temporary preferences only.
- **130 connection-setting checks passed:** the RTT label is hidden before authentication and after cancel/rejection/disconnect, visible while connected, and reset before reconnect. Three correct authentications and one rejection were independently verified by owned loopback servers. No real user Keychain credentials were used.
- **116 protocol sessions passed with AddressSanitizer** on the modified bridge, C test harness and LibVNCClient. The unchanged JPEG dependency used its Release SIMD build. Existing input, fragmented-screen/capability reads, wake storms, view-only, cancellation, JPEG/CopyRect/resize, authentication and quality negotiation cases passed.
- Native deterministic RTT tests cover correct units, unavailable/zero/short/state/error replies, the exact idle boundary, unchanged polling, counter-change activity, reconnect reset and **8,000 concurrent getter calls**.
- The dedicated idle fixture observed a 1 ms loopback estimate and idle after 5,001 ms. Repeated queries added no wire traffic: the server recorded only the original five input messages and two framebuffer requests. This is a loopback correctness result, not a measured LAN or input-to-screen performance claim.

## Window restoration and silent credential failures

- **39 window-placement checks passed**, including 23 pure geometry cases and isolated invisible-window autosave/restore. Two adjusted sizes (860×540 and 1180×760) and noncentered positions restore after simulated initial UI setup. Missing placement centers; valid placement is preserved. Synthetic screen layouts cover removed, negative-origin, spanning and oversized cases. Explicit saves skip fullscreen/unnamed windows. Tests use only UUID autosave names and clean them afterward.
- Production restoration now runs after UI/settings setup, before enabling native autosave, and centers only if no usable placement exists. Normal window placement is saved on quit/close. Headless controller tests still never register or write the production frame name. Per-endpoint Fit/custom zoom remains separate and the server's framebuffer resolution is unchanged.
- All credential methods are noninteractive; the approval button and interactive storage API were removed. Read/save/delete failures are inline, without a password authorization sheet. Failed saves leave Remember off. Stale connected tooltips and endpoint subtitles are cleared after disconnect/failure and when selecting another saved profile.
- **95 password-store checks passed**, including 71 deterministic noninteractive-policy/error checks, 32 concurrent synthetic operations, and isolated UUID login-Keychain CRUD/cleanup. No existing user credential was read.
- A bounded synthetic signing experiment did **not** prove cross-update credential access: changed binaries with the same certificate, identifier, name and installation path still received `errSecAuthFailed` when reading the other build's test item. All test credentials/private keys/apps were removed, and default/search lists/trust stayed unchanged. No production signing identity or permissions were changed. Current [Apple securityd classification](https://github.com/apple-oss-distributions/Security/blob/main/securityd/src/clientid.cpp#L259) falls back to code-hash partitions for this signing class.
- **Remaining credential limitation:** earlier ad hoc saved items may be inaccessible after updates. This release prevents authorization prompts and reports failures honestly; it does not claim that cross-update password reuse or legacy-item migration is fixed. Protected old items remain unchanged.

## Scope

No renderer, JPEG quality, encoding preference, server resolution or saved viewing preference was changed for this feature. The previous [Preview 5 validation](TEST_RESULTS-1.1.0-preview.5.md) remains historical evidence for its dirty-region/GPU optimization; those counts are not claimed as new hardware runs here.

Private owner network diagnostics are kept outside the public repository and archives. Physical external-display transitions, the full manual hardware matrix, Developer ID signing and notarization remain pending. This remains an ad hoc signed preview. Any post-installation live observation is recorded separately in the release notes.
