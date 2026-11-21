# Preview 3 validation — 21 November 2026

Preview 3 adds private-LAN VNC discovery, automatic selection of a lone result, confirmed aliases, and opt-in macOS Keychain passwords. It remains an ad hoc signed early-access preview.

| Check | Result |
| --- | --- |
| Discovery backend | 87 checks: subnet bounds, banners, malformed/silent servers, timeout, cancellation, stale callbacks, socket closure. |
| Real Keychain | 52 isolated classic login-Keychain checks: CRUD, endpoint/service isolation, UTF-8, validation and exact cleanup. Prompts disabled, synthetic values only. |
| Connection settings | 73 controller checks plus independent loopback proof of 3 accepted password sessions and 1 rejected attempt. Profile aliases save before authentication; passwords save only after success. |
| Discovery picker | 81 checks: lone-result selection, default/saved alias, blank-name guard, stable names across progress/completion, retry, cancellation and lifetime-safe confirmation. |
| Viewport | 378 deterministic geometry checks. |
| Metal/input | 622 actual native checks, large desktops and 40 resize cases. |
| Main controller | 3406 actual AppKit layout/navigation checks across four window sizes, temporary preferences and synthetic 5K frames. |
| VNC protocol | 45 mock sessions with AddressSanitizer: frames/Tight, auth, view-only, stalls/cancel, size limits, drop/refusal. |

A real scan of the newly selected private Wi-Fi checked 253 other addresses on TCP5900 and found one valid RFB3.8 greeting. No authentication, password or input was sent. Public reports omit private addresses.

Testing found an edited alias could reset when final results were reordered. Both progress and completion now preserve the selected endpoint and typed name; the revised81-check picker suite passed.

The full release command passed before the final single-result UX refinement. The revised settings and picker suites passed afterward. The final application is rebuilt, arm64/signature checked and packaged separately. Rendering/input source remains unchanged.

Keychain uses the working classic macOS login Keychain with OS encryption/access controls and synchronization disabled; this does not claim Data Protection ThisDeviceOnly semantics or universal backup exclusion.

Remaining limits: private IPv4 physical LANs only, one selected port, a local /24 cap for wider networks. No IPv6, Bonjour, VPN discovery or port sweep. Blocked/slow servers may need manual entry. Physical external-display transitions and notarization remain pending. This is not a stable-release guarantee.
