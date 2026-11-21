# Release checklist — 1.1.0-preview.5

**Status: preview candidate. Manual hardware checks are not complete.** Empty boxes and matrix cells mean not run. Implemented behavior and targeted automated checks are not proof that a hardware scenario passed. Keep failed or unavailable cases visible with a reason and a linked issue.

Targeted results for this preview are recorded in the [Preview 5 validation report](TEST_RESULTS-1.1.0-preview.5.md). The [Preview 4 report](TEST_RESULTS-1.1.0-preview.4.md) remains historical evidence. The full physical-display matrix below remains a gate for a stable release; publishing a prerelease does not mark those cells as passed.

## Targeted discovery observation — 2026-11-21

After changing Wi-Fi, a production-backend scan of exactly one current private IPv4 Wi-Fi `/24` checked 253 other addresses on TCP 5900 and found one endpoint with a valid RFB 3.8 greeting. It sent no authentication, passwords, or remote input. This confirms discovery on that network at that time; it is not an authenticated-session, alias-UI, or general network-compatibility result. Private addresses are omitted from this public record.

The [Preview 1 test report](TEST_RESULTS-1.1.0-preview.1.md) remains historical evidence for that candidate; its counts do not establish the new discovery or Keychain behavior.

## Record the candidate and environment

- [ ] Commit, app version, build number, build date, and package hashes recorded.
- [ ] macOS version, Mac/GPU model, physical display mode, backing scale, and server/version recorded.
- [ ] Confirm user docs match the implemented Auto/zoom/Hand/sidebar controls and labels.
- [ ] Both app and matching source archive built from the candidate commit.
- [ ] Native arm64 executable and ad hoc signature checked; signing/notarization status stated accurately.
- [ ] Build and relevant automated tests pass; sanitizer results are recorded separately from UI results.

Use a disposable VNC desktop with synthetic content: labeled corners, an edge grid, center crosshair, a scrolling test page, and click targets at known remote coordinates. Do not collect a personal desktop or real credentials as release evidence.

## Resolution and window matrix

For **every cell**, run the display/navigation sequence below. Local dimensions are Mac window sizes in points; also record the resulting remote-image viewport size. The MacBook case means a normally usable window on its built-in display, with its actual dimensions recorded. Test a 1× external display and a 2× Retina display where available. An unavailable combination remains **not run**, with its hardware limitation stated.

| Remote framebuffer | 860 × 540, 1× | 860 × 540, 2× | 1180 × 760, 1× | 1180 × 760, 2× | MacBook window, 1× | MacBook window, 2× |
| --- | --- | --- | --- | --- | --- | --- |
| 1280 × 720 | Not run | Not run | Not run | Not run | Not run | Not run |
| 1920 × 1080 | Not run | Not run | Not run | Not run | Not run | Not run |
| 2560 × 1440 | Not run | Not run | Not run | Not run | Not run | Not run |
| 5120 × 2880 | Not run | Not run | Not run | Not run | Not run | Not run |

If the app's minimum window size prevents a requested case, record the actual minimum and treat that case as blocked rather than replacing it silently. A 1× “MacBook window” case may require a same-size window on an external display; identify the substitution.

### Display/navigation sequence for each cell

| Check | Expected result | Result/evidence |
| --- | --- | --- |
| Connect and choose Fit | Complete image visible, aspect preserved, correct centering/letterboxing, no clipped controls. | Not run |
| Choose Auto (Readable) | Uses max(100%, min(Fit zoom, 200%)) in backing pixels; large remote desktops are not shrunk below 100% and remain navigable. | Not run |
| Choose 50%, 75%, 100%, 125%, 150%, 200% | Each percentage uses a consistent remote-to-backing-pixel scale; labels and metrics agree. Pinch also produces Custom values within 10–400%. | Not run |
| At 100% | One remote pixel maps to one drawable/backing pixel. macOS scaled-panel resampling is documented separately. | Not run |
| Pan to every corner and the center at oversized scales | All edges and corner targets reachable. Offset clamps at the real content edges; no blank overscroll hides content. | Not run |
| Use native scrollers | Scrollers visible and usable whenever scaled content exceeds the viewport. Thumb range and knob size follow content/viewport dimensions. | Not run |
| Use Hand drag, wheel/trackpad, and arrows; then Escape | Moves the local view without remote input. Escape exits Hand. Held remote input is released safely on mode/focus changes. | Not run |
| Scroll normally over the remote image | Remote wheel input reaches the server without unexpected local panning. Horizontal direction is correct. | Not run |
| Click known targets after Fit, each zoom, and panning | Server receives the expected remote coordinates within rounding tolerance; all four corners and center tested. Letterbox clicks do not activate unrelated remote targets. | Not run |
| Drag from inside the image to/outside an edge and release | Coordinates clamp appropriately; no stuck remote button. | Not run |
| Resize between landscape, narrow, and tall shapes | Viewport and scrollers update; selected zoom policy persists; full desktop remains reachable. | Not run |
| Toggle sidebar, full screen, and return | Sidebar shortcut Control–Command–S works; full screen hides/restores sidebar. No stale drawable or transform; pointer mapping remains correct. | Not run |

The listed controls are implemented in the preview candidate. Record their observed results rather than treating implementation as a pass. Also exercise Control–Command–+ / − / 0 and verify custom pinch zoom boundaries of 10% and 400%.

## Display transitions and renderer checks

- [ ] Move a connected window from a 2× Retina display to a 1× external display and back, in Fit and custom zoom.
- [ ] Disconnect/reconnect the external display while connected; verify the viewport, scale, scrollers, focus, and pointer coordinates.
- [ ] Change macOS display scaling and re-check reported backing scale, text readability, and 100% behavior.
- [ ] Resize the remote desktop during a live session in Fit and oversized/custom mode; verify new bounds, clamped pan offsets, texture replacement, and pointer mapping.
- [ ] Reconnect to a different remote resolution; old content, offsets, held input, and frame counters do not leak into the new session.
- [ ] Confirm Metal drawable dimensions follow the local viewport and backing scale, rather than the entire oversized remote desktop.
- [ ] Confirm an idle desktop is not rendered continuously without a reason, and incoming frames coalesce without an unbounded queue.
- [ ] Exercise rapid frame updates, zoom/resize, and clear/reconnect; no Metal validation errors, CPU/GPU texture hazards, crash, or progressive memory growth.

## Connection, input, and state regression

| Scenario | Expected result | Result/evidence |
| --- | --- | --- |
| Server with no authentication, on a disposable test network | Connects when offered/supported, without a password prompt loop. | Not run |
| Classic VNC password; correct and incorrect values | Correct challenge response succeeds; failure is useful and leaves the app reconnectable. Passwords absent from logs/profiles/feedback. | Not run |
| Refused connection, timeout, stalled handshake, disconnect during connect | UI remains responsive; cancellation/cleanup completes; retry works. | Not run |
| Server closes an established connection | Status updates, input stops, and reconnection works. | Not run |
| Repeated connection/disconnection and device switching | One active session; no stale callbacks, frames, or held input. | Not run |
| View only enabled before connect and while connected | No keyboard, pointer, clipboard-send, or local-pan-induced input reaches server. Previously held input is released safely. | Not run |
| Server grants view-only access | Client does not suggest its checkbox can override server permissions. | Not run |
| Keyboard modifiers, function keys, Command-to-Control, focus loss | Correct key messages; no stuck keys; Mac app/window shortcuts remain usable. | Not run |
| Text clipboard disabled, enabled, manually sent, and view-only | Transfers only as configured; no feedback loop; no file/image-transfer claim. | Not run |
| Unicode text with UTF-8 and legacy clipboard servers | Supported characters round-trip; legacy replacement behavior documented; oversized messages bounded. | Not run |
| Three saved devices, rename/remove, unsaved one-off connection | Profiles persist locally without passwords; opt-in passwords use Keychain separately; one active session. | Not run |
| Feedback export and external feedback/support links | Export stays local until shared; no credentials/private address added automatically; no payment/account gate. | Not run |
| Oversized/malformed remote framebuffer | Client rejects unsupported allocation safely and remains usable. | Not run |

## Discovery and optional password regression

| Scenario | Expected result | Result/evidence |
| --- | --- | --- |
| Find on private Wi-Fi/Ethernet, selected default/custom port | Only the selected TCP port is checked. Actual subnet mask is respected, with larger subnets limited to the local `/24` neighborhood; at most 32 concurrent probes. | Targeted backend observation above; full UI/network matrix not run |
| Public IPv4, VPN, IPv6-only, or no supported interface | No unsupported network is scanned; manual-address fallback remains available. | Not run |
| Fragmented/malformed greeting or silent endpoint | Only a valid 12-byte RFB greeting creates a result; probes time out without authentication or input. | Not run |
| Cancel, change network, retry, then close the picker | Connections close; prior-scan callbacks do not repopulate results; no retained sheet/controller prevents another search. | Not run |
| Select a result during search and on completion | Selection stays on the same server; Save Computer fills host/port and saves the confirmed alias without connecting. A lone result is selected automatically. | Not run |
| Confirmed discovery alias, successful/failed login, saved-device rename | Confirming the alias persists the profile before authentication; password saving still requires successful authentication. Blank names are rejected, capacity stays at three, and Rename… changes a saved device name. | Not run |
| Remember password off for a new endpoint | Connection succeeds without a Keychain write; no plaintext password in preferences, profiles, or feedback. | Not run |
| Opt in with correct/incorrect password, cancellation, and connection failure | Only a successful connection saves the password for that host/port. Failed authentication and cancellation do not save it. | Not run |
| Reconnect, change host/port, switch device | Correct endpoint's password loads when available; previous endpoint's credential is cleared before another endpoint is used. | Not run |
| Uncheck Remember password; remove a device | Endpoint's Keychain item is deleted; profile removal also deletes its password. A failed deletion is reported without claiming success. | Not run |
| Locked/denied/unavailable Keychain or failed save | Error is useful, secrets stay out of logs/exports, and manual password entry/connection remains possible. | Not run |
| Automatic startup/reconnect with an inaccessible saved item | No macOS authentication dialog. The optional Use saved password… button is the only path that can ask for Keychain approval; canceling preserves manual entry. | See Preview 4 validation report |
| First connection and per-endpoint settings after restart | New endpoints default to Fit/Wi-Fi; selected zoom and quality persist independently for each host/port. | See Preview 4 validation report |

## Known limits and publication gate

- [ ] Record remaining issues, affected setups, and practical workarounds in the changelog/wiki. Mark untested real-server/hardware combinations explicitly.
- [ ] State macOS 13+/Apple Silicon requirements, one active session, and three saved devices accurately.
- [ ] Explain discovery's private IPv4/single-port/subnet bounds and manual-address fallback; state that a greeting is not proof of identity or authentication.
- [ ] Explain opt-in classic macOS login Keychain storage, save-after-success behavior, endpoint matching, and deletion. Do not claim Data Protection `WhenUnlockedThisDeviceOnly` semantics or exclusion from every backup.
- [ ] State no built-in transport encryption/tunnel, cloud relay, audio, file transfer, printing, or recording.
- [ ] State current framebuffer limits (16,384 pixels per axis, 256 MiB total) and text-clipboard limit (1 MiB).
- [ ] State ad hoc signing and notarization status accurately; do not claim Apple approval.
- [ ] Verify downloadable app/source hashes match the candidate, source includes docs/community files and licenses, and website links work.
- [ ] Make no benchmark, compatibility, or security claim beyond recorded evidence.
- [ ] Change the preview changelog entry to a stable 1.1.0 release only after required results and remaining limitations have been reviewed.

Keep this checklist with the release evidence. Automated geometry/protocol tests and native UI/hardware checks answer different questions; identify which kind supports each result.
