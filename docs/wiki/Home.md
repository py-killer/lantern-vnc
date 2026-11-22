# Lantern VNC wiki

Lantern is a free native VNC viewer for Apple Silicon Macs running macOS 13 or later. It connects directly to an existing VNC server such as TightVNC. The app has no Lantern account, expiry, subscription, or payment gate.

| Guide | What it covers |
| --- | --- |
| [Getting started](Getting-Started.md) | Find a server, name computers, switch screen cards, and add local websites. |
| [Display and navigation](Display-and-Navigation.md) | Sampled previews, Fit, saved presets, large desktops, and local versus remote input. |
| [Troubleshooting](Troubleshooting.md) | Connection, authentication, display, and input problems. |
| [FAQ](FAQ.md) | Compatibility, network RTT, clipboard behavior, privacy, and project limits. |

These pages describe **1.2.0-preview.1, build 11**. Named cards show RAM-only previews for connected VNC computers and loaded WebKit pages. Saved VNC computers can remain connected read-only in the background; only the selected computer receives remote input. Local website cards keep their own browser session inside Lantern. New VNC endpoints still start in Fit with the Wi-Fi high-quality preset; the existing Metal viewport, rendering and passive RTT indicator are preserved.

This remains a preview. Browser downloads and some popup/OAuth flows are unsupported, reliable Keychain access across ad hoc updates remains unresolved, and physical external-display transitions and the complete manual hardware matrix remain unverified. See the [current test report](../TEST_RESULTS-1.2.0-preview.1.md), [changelog](../../CHANGELOG.md), and [release checklist](../RELEASE_CHECKLIST.md); unchecked cases are not passes.

## Feedback and contributions

Search [existing issues](https://github.com/py-killer/lantern-vnc/issues) or open a [bug report or feature request](https://github.com/py-killer/lantern-vnc/issues/new/choose). Include the app version and reproducible steps. For a display issue, include the remote resolution, local window size, display scale, and selected viewing mode.

Issues are public. Remove passwords, private server addresses, clipboard contents, and personal desktop information before sharing notes or screenshots. The app's **Help → Save Feedback…** command writes a local file; it does not submit that file automatically.

See [Contributing](../../CONTRIBUTING.md), the [code of conduct](../../CODE_OF_CONDUCT.md), and [security policy](../../SECURITY.md).
