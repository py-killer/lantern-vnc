# Lantern VNC wiki

Lantern is a free native VNC viewer for Apple Silicon Macs running macOS 13 or later. It connects directly to an existing VNC server such as TightVNC. The app has no Lantern account, expiry, subscription, or payment gate.

| Guide | What it covers |
| --- | --- |
| [Getting started](Getting-Started.md) | Open the app, find a local server, name a device, and optionally remember its password. |
| [Display and navigation](Display-and-Navigation.md) | Fit, saved zoom/picture presets, large desktops, and local versus remote scrolling. |
| [Troubleshooting](Troubleshooting.md) | Connection, authentication, display, and input problems. |
| [FAQ](FAQ.md) | Compatibility, network RTT, clipboard behavior, privacy, and project limits. |

These pages describe the implemented **1.1.0-preview.6**, including local-server discovery, optional Keychain passwords, saved viewing preferences, and a passive TCP RTT indicator. New endpoints start in Fit with the Wi-Fi high-quality preset. The existing dirty-region rendering improvements are preserved; RTT adds no probes or picture-quality changes. It is a preview, not a stable-release claim: physical external-display transitions and the complete manual hardware matrix remain unverified. See the [changelog](../../CHANGELOG.md) and [release checklist](../RELEASE_CHECKLIST.md); unchecked cases are not passes.

## Feedback and contributions

Search [existing issues](https://github.com/py-killer/lantern-vnc/issues) or open a [bug report or feature request](https://github.com/py-killer/lantern-vnc/issues/new/choose). Include the app version and reproducible steps. For a display issue, include the remote resolution, local window size, display scale, and selected viewing mode.

Issues are public. Remove passwords, private server addresses, clipboard contents, and personal desktop information before sharing notes or screenshots. The app's **Help → Save Feedback…** command writes a local file; it does not submit that file automatically.

See [Contributing](../../CONTRIBUTING.md), the [code of conduct](../../CODE_OF_CONDUCT.md), and [security policy](../../SECURITY.md).
