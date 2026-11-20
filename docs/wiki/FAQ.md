# Frequently asked questions

[Wiki home](Home.md) · [Getting started](Getting-Started.md) · [Troubleshooting](Troubleshooting.md)

## Is Lantern free? Do I need an account?

Yes, it is free to use and keep using. There is no Lantern login, expiry, subscription, license server, or paid feature unlock. Tips are optional and never change access. GitHub may require its own sign-in to submit an issue; that is not required to run the app.

## Which Macs and servers does it support?

The supplied arm64 app requires an Apple Silicon Mac and macOS 13 or later. It connects to an existing RFB/VNC server such as TightVNC and supports classic VNC password authentication and common encodings. It does not provide a RealVNC cloud account or enterprise identity login. Compatibility with a particular server configuration should be tested rather than assumed.

## How many devices can I save?

Up to three named device profiles, with one remote session active at a time. Profiles contain a name, host, and port; passwords are not saved. You can still enter a one-off connection when all saved slots are occupied.

## Why does 100% look small on my Retina screen?

It maps remote pixels to drawable/backing pixels rather than treating each remote pixel as a full Mac point. The final appearance also depends on macOS display scaling. In 1.1.0-preview.1, Auto (Readable) avoids shrinking below 100%; choose 125–200% for larger text and use scroll bars or Hand to navigate. Fit to Window gives a whole-desktop overview. None of these controls changes the remote operating system's resolution. See [Display and navigation](Display-and-Navigation.md).

## Why does scrolling move the remote app instead of my view?

With Hand off, wheel/trackpad scrolling is sent to the remote computer. Turn on **Hand** for local drag/scroll/arrow-key panning, or use the native scroll bars. Escape leaves Hand mode.

## Is the new navigation release fully verified?

1.1.0-preview.1 is a local preview candidate with the new controls implemented. Physical 1× external/2× Retina transitions, monitor disconnect/reconnect, and the complete manual hardware matrix remain unverified. Read the [release checklist](../RELEASE_CHECKLIST.md) before treating it as a stable release.

## Does resizing Lantern change the remote resolution?

No. The server reports the remote desktop size. Lantern scales or navigates that image locally. If the server changes its desktop size, the viewer must handle the new size separately from a Mac window resize.

## Is the connection encrypted?

Not by this build. Use a trusted LAN or a VPN/SSH tunnel that you establish separately. Lantern does not create a secure tunnel or relay. Do not expose an unencrypted VNC service directly to the internet.

## Does Lantern send analytics or save my password?

It has no account, analytics, licensing, or cloud-relay service. Device settings are stored locally. The app does not write VNC passwords to saved profiles or feedback exports. Optional clipboard sharing deliberately transfers text between your Mac and the selected server; leave it disabled if you do not want that transfer.

## Does it support file transfer, audio, printing, or multiple sessions?

The current app provides display, keyboard/pointer input, and optional text clipboard sharing. It does not provide file transfer, remote audio, printing, recording, or concurrent remote sessions.

## Why does macOS warn when I open the app?

The current preview is ad hoc signed. Apple Developer ID signing and notarization are pending. Approve only a copy from a source you trust; do not disable Gatekeeper system-wide. See [Getting started](Getting-Started.md).

## Where are the source and release notes?

The [repository](https://github.com/py-killer/lantern-vnc) and matching source archive contain the app, bridge, vendor sources, build scripts, tests, and license notices. See the [changelog](../../CHANGELOG.md). Original project contributions use GPL-2.0-or-later; third-party components retain their notices. No warranty or support deadline is promised.

## How do I help?

Report a reproducible issue, improve documentation, or submit a focused fix. The [contribution guide](../../CONTRIBUTING.md) explains how to build and check a change. Optional support is a thank-you rather than a requirement.
