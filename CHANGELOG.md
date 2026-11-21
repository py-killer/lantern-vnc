# Changelog

## 1.1.0-preview.6 — 2026-11-21

- Build 10: removing a device clears its profile and saved viewing preferences and frees the slot even when deletion of a protected saved password fails. An inline notice says that the credential was retained; removal never opens an authentication dialog or offers an approval action.
- Restore the last normal window size and position instead of centering it on every launch. Recover saved offscreen placement when its monitor is unavailable. Window geometry is separate from per-endpoint zoom/picture settings and never changes the server's resolution.
- Show an **RTT** line beneath the connection status while connected, refreshed once per second from macOS's passive smoothed TCP estimate. Missing or zero estimates display **RTT unavailable**.
- Remove the saved-password approval action and forbid authentication UI for every Keychain read, save, and deletion. Report errors inline and turn Remember password off after a failed save. Leave inaccessible old items unchanged, with no plaintext fallback or security reset. Cross-update persistence with ad hoc signing remains unverified.
- Mark the estimate **idle** after five seconds without an observed transport-counter change. Activity age describes observed traffic, not the age of the kernel's RTT sample.
- Keep the scope clear: RTT is to the TCP peer, which can be a local forwarding endpoint. It excludes input-to-screen latency; slow capture, encoding, decoding, and rendering can coexist with low RTT.
- Add no diagnostic probes, synthetic input, screen-update requests, or analytics. Preserve picture presets, decoded pixel quality, and the Preview 5 rendering path.
- Remain an ad hoc signed preview with physical external-display transitions, the full manual hardware matrix, Developer ID signing, and notarization pending.

## 1.1.0-preview.5 — 2026-11-21

- Copy decoded dirty regions into one owned image and update only the changed texture regions. Keep independent accumulated changes for each display buffer, with generation checks around resize and clear. The production upload path avoids an extra packed-image snapshot.
- Service queued input on the existing connection thread while a partial server message waits for more bytes. Stage capability flags until their complete message arrives, so input does not use a partly received capability set.
- Preserve decoded pixel quality, picture presets, Fit defaults, per-endpoint settings, and the server's resolution. These changes reduce local copying and improve input servicing; they do not change VNC wire compression or guarantee Wi-Fi speed.
- Add seeded pixel-oracle, stale-buffer, immutable-snapshot, direct-upload, resize, and concurrency tests, plus CPU copy measurements at 5K. Extend owned mock/GPU tests for fragmented messages and dirty updates. CPU measurements are not network, GPU, or end-to-end benchmarks; see the versioned test report for observed results.
- Remain an ad hoc signed preview. Physical external-display transitions, the full manual hardware matrix, Developer ID signing, and Apple notarization are still pending.

## 1.1.0-preview.4 — 2026-11-21

- Label the sidebar toolbar action **Hide settings / Show settings** so it is easier to find. Collapsing it expands the remote desktop; the button and Control–Command–S restore it.
- Start new endpoints in **Fit to Window** with **Wi-Fi · high quality** selected. Auto, explicit zoom, pinch, and Hand remain available when fitted text is too small.
- Remember zoom mode/custom scale and picture preset separately for each host and port across restarts. Pan positions are not restored. Migrate the previous global picture preset once for existing devices, then keep endpoint settings independent.
- Add the Wi-Fi preset: request Tight JPEG level 8, matching Balanced, with moderate compression level 3 instead of 1. This trades potential server CPU work for smaller transfers; it is not adaptive and does not guarantee a speed increase. Balanced, Lossless, and Fast keep their previous settings. Picture changes apply on the next connection.
- Preserve lossless compressed transfer with JPEG disabled. JPEG-enabled presets can affect text; coarse quality levels are not percentages.
- Keep automatic Keychain reads, saves, and deletions silent, including startup and reconnect. This version offered an optional saved-password approval action; Preview 6 removes that action and makes all Keychain operations noninteractive. Manual VNC password entry remains available, with no plaintext fallback or Keychain security reset.
- Extend the protocol suite with compression/JPEG negotiation and an embedded Tight JPEG decoding fixture. A local AddressSanitizer run passed 75 repeated sessions, including existing authentication, cancellation, input, and cleanup cases. This is correctness evidence, not a performance benchmark.
- Remain a preview: physical external-display transitions, the full manual hardware matrix, Developer ID signing, and Apple notarization are pending.

## 1.1.0-preview.3 — 2026-11-21

- Add **Find…** beside Server to search the selected VNC port on private IPv4 Wi-Fi/Ethernet networks. Search is bounded, cancellable, and confirms RFB greetings without authentication. Broader subnets use the local `/24` neighborhood; VPNs, IPv6, Bonjour, and port sweeps remain outside discovery.
- Select a lone discovery result automatically, ask the user to confirm its alias, and save that named profile immediately. Existing devices can be renamed with **Rename…**. Manual connections can still use the server's desktop name after authentication.
- Add opt-in **Remember password**, using the classic macOS login Keychain separately from device profiles. Passwords save only after a successful connection. Unchecking removes the endpoint's password; removing a device also removes its password. Plaintext passwords are never saved in preferences or profiles. Keychain errors preserve manual entry.
- Keep discovery retry/manual-address fallbacks and clear a previous endpoint's credential when the host or port changes.
- Preserve the earlier display/navigation implementation. Physical external-display transitions, the complete manual hardware matrix, Developer ID signing, and Apple notarization remain pending. This is a preview, not a stable-release claim.

## 1.1.0-preview.2 — 2026-11-20

- Refine the original macOS app icon and route Help → Send Feedback to the no-account website form.
- Publish the static Wiki, anonymous feedback receipts, and a no-payment interest poll.
- Add optional first-party website counts and a private owner dashboard/inbox; the Mac app sends no analytics.
- Fix source packaging recursively including earlier downloadable source archives.
- Preserve the Preview 1 renderer and input implementation and its recorded automated checks. Native display hardware coverage and Apple notarization remain pending.

## 1.1.0-preview.1 — 2026-11-20

This local candidate supersedes the 1.0 navigation implementation, which had large-desktop scaling and edge-navigation issues. The following controls are implemented; the candidate is not a fully verified stable release.

### Display and navigation

- Render into a fixed visible Metal viewport, with a pan-offset model and one transform for rendering and remote pointer coordinates.
- Default to **Auto (Readable)** using `max(100%, min(Fit zoom, 200%))` in drawable/backing pixels. Large desktops remain at 100% and can be navigated instead of shrinking to fit.
- Offer **Fit to Window**, explicit 50/75/100/125/150/200% zoom, and custom trackpad pinch zoom from 10% to 400%.
- Keep native scrollers visible on axes where the image exceeds the viewport.
- Add **Hand** for local drag, scroll, and arrow-key panning; Escape exits Hand. Normal scrolling with Hand off controls the remote app.
- Add sidebar visibility controls and **Control–Command–S**, zoom shortcuts **Control–Command–+ / − / 0**, and sidebar restoration around full screen.
- Keep server resolution unchanged when viewing mode, local window size, or pan position changes.

### Documentation and community

- Add versioned wiki guides for setup, display controls, troubleshooting, and common questions.
- Add contribution, conduct, and security guidance, issue forms, and a pull request template.
- Add a release checklist covering resolution, window size, Retina scale, navigation, input coordinates, and connection behavior.

### Verification limits

Automated geometry/protocol tests and synthetic native GPU checks do not establish full hardware compatibility. Physical 1× external/2× Retina transitions, monitor disconnect/reconnect, macOS scaled display modes, and the complete manual matrix remain unverified. Results and remaining limits must be reviewed before declaring a stable release. See [the release checklist](docs/RELEASE_CHECKLIST.md).

## 1.0

Initial native Apple Silicon viewer with AppKit controls, Metal rendering, and a compiled LibVNCClient/libjpeg-turbo engine.

- Connect directly to a VNC server using a host, TCP port, and classic VNC password authentication where required.
- Control the remote desktop with keyboard and pointer input; optionally share text clipboard data.
- Choose Fit or 100% display mode, View only, and Balanced/Lossless/Fast picture quality.
- Save up to three device profiles with one active session. Passwords are not saved in those profiles.
- Provide local feedback export, optional support links, complete corresponding source, and third-party license notices.
- Require no Lantern login, subscription, expiry, or paid feature unlock.

Builds are ad hoc signed and have not been Apple-notarized. VNC transport encryption, cloud relay, audio, file transfer, and remote printing are not included.
