# Frequently asked questions

[Wiki home](Home.md) · [Getting started](Getting-Started.md) · [Troubleshooting](Troubleshooting.md)

## Is Lantern free? Do I need an account?

Yes, it is free to use and keep using. There is no Lantern login, expiry, subscription, license server, or paid feature unlock. Tips are optional and never change access. GitHub may require its own sign-in to submit an issue; that is not required to run the app.

## Which Macs and servers does it support?

The supplied arm64 app requires an Apple Silicon Mac and macOS 13 or later. It connects to an existing RFB/VNC server such as TightVNC and supports classic VNC password authentication and common encodings. It does not provide a RealVNC cloud account or enterprise identity login. Compatibility with a particular server configuration should be tested rather than assumed.

## How many devices can I save?

Up to three named device profiles, with one remote session active at a time. Profiles contain a name, host, and port. In Find, confirm an alias with **Save Computer** to save the profile immediately; this does not connect or save a password. A new profile saved after connecting can use the server's desktop name. Use **Rename…** to change its name. Passwords are kept separately in macOS Keychain only if you opt in. You can still enter a one-off connection when all saved slots are occupied.

## Can I find a server without checking my router?

Choose **Find…** beside Server. It checks the selected port, normally `5900`, on active private IPv4 Wi-Fi/Ethernet networks. It respects the subnet mask, with larger subnets limited to the local `/24` neighborhood. It reads only the VNC greeting, without authentication or credentials, and can be canceled or retried.

It does not search VPN interfaces, IPv6, Bonjour, public IPv4 networks, or every port. Use a manual address when the server is outside the searched area. A result confirms a VNC greeting, not its identity or your permission to control it.

## Why does 100% look small on my Retina screen?

In 1.1.0-preview.6, a new endpoint starts in **Fit to Window**, which shows the whole desktop but can make text tiny on a 5K server. Choose **Auto (Readable)** to avoid shrinking below 100%, or 125–200% for larger text, then use scroll bars or Hand to navigate.

At 100%, one remote pixel maps to one drawable/backing pixel, rather than one Mac point. The final appearance also depends on macOS display scaling. These controls change only the local view, not the remote resolution or the number of remote pixels requested. See [Display and navigation](Display-and-Navigation.md).

## Which picture preset should I use on Wi-Fi?

New endpoints default to **Wi-Fi · high quality**. It requests the same Tight JPEG quality as Balanced, with a higher compression level for non-JPEG data. More compression can use more server CPU; it is not a guarantee of faster updates.

| Preset | Requested Tight JPEG level | Compression level |
| --- | --- | --- |
| Wi-Fi · high quality | 8 | 3 |
| Balanced | 8 | 1 |
| Lossless | JPEG disabled | 1 |
| Fast | 5 | 1 |

JPEG levels are protocol settings, not percentages; the server decides how to encode each rectangle. JPEG-enabled presets do not guarantee lossless text. **Lossless** retains compression while requesting exact pixels without JPEG; fractional local zoom can still soften their displayed appearance. Picture changes apply on the next connection. Lantern does not adapt the preset automatically.

## Does Preview 5 change picture quality or reduce network traffic?

Its dirty-region optimization reduces local CPU copying and GPU texture updates for small changes. It preserves the decoded pixels, picture preset, and server resolution. It does not change the requested VNC encodings or compression levels, so this local optimization makes no claim of smaller network transfers. Queued input can be serviced while a fragmented screen update waits for more bytes; network and server delays can still dominate. The recorded copy benchmark measures local CPU work, not Wi-Fi or end-to-end performance.

## What does the RTT number measure?

It is macOS's passive, smoothed TCP round-trip estimate for the connected TCP peer, refreshed in the interface once per second. It excludes input-to-screen delay. Slow capture, encoding, decoding, or rendering can still make a desktop lag when RTT is low. With a local SSH port forward or TCP proxy, it can measure the forwarding endpoint rather than the remote computer.

A dash means no usable estimate; **idle** appears after five seconds without an observed traffic-counter change. Activity age is not RTT sample age, and polling does not force a new sample. The indicator sends no extra probes, input, or frame-update requests, collects no analytics, and does not change picture quality. See [Read network RTT](Display-and-Navigation.md#read-network-rtt) for details and primary references.

## Does Lantern remember zoom and picture settings?

Yes. Fit, Auto, an explicit percentage, or custom pinch zoom and the picture preset are saved per host and TCP port, including across app restarts. Pan positions are not remembered. Changing the host or port selects a different endpoint's preferences. Upgrading imports the old global picture setting once for existing saved devices; a new endpoint uses Fit and Wi-Fi · high quality.

## Why does scrolling move the remote app instead of my view?

With Hand off, wheel/trackpad scrolling is sent to the remote computer. Turn on **Hand** for local drag/scroll/arrow-key panning, or use the native scroll bars. Escape leaves Hand mode.

## Is the new navigation release fully verified?

1.1.0-preview.6 is an early-access release with the new controls implemented. Physical 1× external/2× Retina transitions, monitor disconnect/reconnect, and the complete manual hardware matrix remain unverified. Read the [release checklist](../RELEASE_CHECKLIST.md) before treating it as a stable release.

## Does resizing Lantern change the remote resolution?

No. The server reports the remote desktop size. Lantern scales or navigates that image locally. If the server changes its desktop size, the viewer must handle the new size separately from a Mac window resize.

## Is the connection encrypted?

Not by this build. Use a trusted LAN or a VPN/SSH tunnel that you establish separately. Lantern does not create a secure tunnel or relay. Do not expose an unencrypted VNC service directly to the internet.

## Does Lantern send analytics or save my password?

It has no account, analytics, licensing, or cloud-relay service. Device settings are stored locally. **Remember password** is off for a new host/port and saves only after a successful connection, using the classic macOS login Keychain with synchronization disabled. Plaintext passwords are never saved in preferences or profiles, or automatically included in feedback exports. Review your own notes before sharing them. This does not promise exclusion from every backup. Uncheck the box to remove that endpoint's saved password; removing its profile also deletes the password. Keychain failures leave manual entry available.

Optional clipboard sharing deliberately transfers text between your Mac and the selected server; leave it disabled if you do not want that transfer. **Find…** makes bounded connections on your chosen local network and port only when requested.

## Why is there a Use saved password… button?

It appears when a saved password is unavailable through silent Keychain access. Startup, automatic reconnect, and routine password saves/deletions do not open a Mac-password approval dialog. Only an explicit click on **Use saved password…** may ask for your Mac login password to approve Keychain access; this is not the remote VNC password. The button is optional. Enter the VNC password manually instead if you prefer. Lantern keeps the existing storage protections, with no plaintext fallback or Keychain reset.

## Does it support file transfer, audio, printing, or multiple sessions?

The current app provides display, keyboard/pointer input, and optional text clipboard sharing. It does not provide file transfer, remote audio, printing, recording, or concurrent remote sessions.

## Why does macOS warn when I open the app?

The current preview is ad hoc signed. Apple Developer ID signing and notarization are pending. Approve only a copy from a source you trust; do not disable Gatekeeper system-wide. See [Getting started](Getting-Started.md).

## Where are the source and release notes?

The [repository](https://github.com/py-killer/lantern-vnc) and matching source archive contain the app, bridge, vendor sources, build scripts, tests, and license notices. See the [changelog](../../CHANGELOG.md). Original project contributions use GPL-2.0-or-later; third-party components retain their notices. No warranty or support deadline is promised.

## How do I help?

Report a reproducible issue, improve documentation, or submit a focused fix. The [contribution guide](../../CONTRIBUTING.md) explains how to build and check a change. Optional support is a thank-you rather than a requirement.
