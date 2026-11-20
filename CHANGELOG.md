# Changelog

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
