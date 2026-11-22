# Frequently asked questions

[Wiki home](Home.md) · [Getting started](Getting-Started.md) · [Troubleshooting](Troubleshooting.md)

## Is Lantern free? Do I need an account?

Yes, it is free to use and keep using. There is no Lantern login, expiry, subscription, license server, or paid feature unlock. Tips are optional and never change access. GitHub may require its own sign-in to submit an issue; that is not required to run the app.

## Which Macs and servers does it support?

The supplied arm64 app requires an Apple Silicon Mac and macOS 13 or later. It connects to an existing RFB/VNC server such as TightVNC and supports classic VNC password authentication and common encodings. It does not provide a RealVNC cloud account or enterprise identity login. Compatibility with a particular server configuration should be tested rather than assumed.

## How many devices can I save?

Up to three named VNC computer profiles. Profiles contain a name, host, and port. In Find, confirm an alias with **Save Computer** to save the profile immediately; this does not connect or save a password. A new profile saved after connecting can use the server's desktop name. Context-click its card for **Rename…**. Passwords are kept separately in macOS Keychain only if you opt in. You can still enter a one-off connection when all saved slots are occupied.

Connected computers can stay connected while another card is selected. Background sessions become read-only, with requests paced roughly every ten seconds. Only the selected computer receives keyboard, pointer, and optional clipboard input. Returning to a connected card uses the same session; use its **Disconnect** action when you want to stop it. Saved computers with an accessible remembered password can reconnect for previews on launch.

## Are card previews saved or live video?

They are small sampled images kept in RAM, not recordings or saved screenshots. Background VNC requests and computer/browser previews are paced about every ten seconds and preserve aspect ratio; network/server delays can make samples older. After an initial thumbnail, repeated sampling pauses for the selected screen while its main desktop or page runs at normal foreground speed. A disconnected card may retain its labeled last capture. Sample age is not RTT, input delay, or a connectivity check.

Live and connecting screens keep their saved order. Selecting a card does not reorder it. Offline, sleeping or closing screens move to the bottom; when they become live again, their original position among live cards is restored.

## Can I open websites in Lantern?

Choose **Add screen → Browser window…**. The default, **Lantern · inside this window**, uses an internal tabbed WebKit browser. **Safari · opens outside Lantern** and **Google Chrome · opens outside Lantern** use the actual installed apps outside Lantern, keeping their own profiles, website logins and enabled extensions. Only located Safari/Chrome choices appear. Installed-browser cards require an HTTP(S) address and keep their chosen browser type across restarts.

The first explicit installed-browser card selection opens its saved address. Later selections switch to that running app without opening another copy of the address. **Open Website** deliberately opens it again. If the app has closed, selecting its card reopens it. Startup restoration does not automatically launch or focus an external browser. Removing a card does not close the browser. App activation cannot guarantee which window, tab or profile is frontmost; use the actual browser to choose a profile.

Internal Lantern cards keep up to 12 tabs, with **+ / Command–T**, close buttons/**Command–W**, and a fresh new tab after closing the last page. Popup links stay within that same internal window. Back/Forward and **Command–L / R / [ / ]** act on the selected tab; **Command–Shift–[ / ]** or **Control–Tab / Control–Shift–Tab** switches tabs. Reload becomes **Stop** while loading; Stop cancels only the selected tab's pending load and preserves its requested address for retry. Command–R always reloads.

Up to 100 browser cards can be recorded independently of the three-computer limit. At most six internal WebKit windows stay loaded; tabs load lazily and inactive least recently used windows sleep when needed. Restoring their saved URLs/selection can discard unsaved forms/page state. Loaded internal background tabs may keep running scripts/network requests. Existing single-address cards migrate into internal one-tab windows with their aliases and URLs preserved.

## Can I use my installed Chrome extensions and browser logins?

Select **Google Chrome · opens outside Lantern** to use the real Chrome app and the profile/extensions it manages, or Safari for its own profile and extensions. Lantern's internal WebKit browser has a separate persistent website session and does not import either browser's extensions, passwords or cookies. It must not be treated as Chrome or Safari simply because it can open the same website.

External-browser cards do not read profile files, inject plugins, take browser screenshots, or request browser-automation, Accessibility or screen-recording access. They open or activate the actual app. Sites in either browser can have their own sign-in and privacy policies. Internal WebKit downloads are unsupported and reported inline; its HTTP authentication/credential authorization dialogs are disabled. Some OAuth or extension-dependent tasks need the real browser. No Lantern account is required.

## Can I find a server without checking my router?

Choose **Find…** beside Server. It checks the selected port, normally `5900`, on active private IPv4 Wi-Fi/Ethernet networks. It respects the subnet mask, with larger subnets limited to the local `/24` neighborhood. It reads only the VNC greeting, without authentication or credentials, and can be canceled or retried.

It does not search VPN interfaces, IPv6, Bonjour, public IPv4 networks, or every port. Use a manual address when the server is outside the searched area. A result confirms a VNC greeting, not its identity or your permission to control it.

## Why does 100% look small on my Retina screen?

In 1.2.0-preview.2, a new endpoint starts in **Fit to Window**, which shows the whole desktop but can make text tiny on a 5K server. Choose **Auto (Readable)** to avoid shrinking below 100%, or 125–200% for larger text, then use scroll bars or Hand to navigate.

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

**RTT unavailable** means no usable estimate; **idle** appears after five seconds without an observed traffic-counter change. Activity age is not RTT sample age, and polling does not force a new sample. The indicator sends no extra probes, input, or frame-update requests, collects no analytics, and does not change picture quality. See [Read network RTT](Display-and-Navigation.md#read-network-rtt) for details and primary references.

## Does Lantern remember zoom and picture settings?

Yes. Fit, Auto, an explicit percentage, or custom pinch zoom and the picture preset are saved per host and TCP port, including across app restarts. Pan positions are not remembered. Changing the host or port selects a different endpoint's preferences. Upgrading imports the old global picture setting once for existing saved devices; a new endpoint uses Fit and Wi-Fi · high quality.

The last normal window size and position are also remembered across launches, separately from those endpoint settings. If its monitor is missing, reopening recovers the saved placement onto an available screen. Window geometry does not change the server's resolution; full physical-monitor transition coverage remains unverified.

## Why does scrolling move the remote app instead of my view?

With Hand off, wheel/trackpad scrolling is sent to the remote computer. Turn on **Hand** for local drag/scroll/arrow-key panning, or use the native scroll bars. Escape leaves Hand mode.

## Is the new navigation release fully verified?

1.2.0-preview.2 is an early-access release with the new controls implemented. Physical 1× external/2× Retina transitions, monitor disconnect/reconnect, and the complete manual hardware matrix remain unverified. Read the [release checklist](../RELEASE_CHECKLIST.md) before treating it as a stable release.

## Does resizing Lantern change the remote resolution?

No. The server reports the remote desktop size. Lantern scales or navigates that image locally. If the server changes its desktop size, the viewer must handle the new size separately from a Mac window resize.

## Is the connection encrypted?

Not by this build. Use a trusted LAN or a VPN/SSH tunnel that you establish separately. Lantern does not create a secure tunnel or relay. Do not expose an unencrypted VNC service directly to the internet.

## Does Lantern send analytics or save my password?

It has no account, analytics, licensing, or cloud-relay service. Device settings are stored locally. **Remember password** is off for a new host/port and attempts to save only after a successful connection, using the classic macOS login Keychain with synchronization disabled. Plaintext passwords are never saved in preferences or profiles, or automatically included in feedback exports. Review your own notes before sharing them. This does not promise exclusion from every backup. After disconnecting, unchecking the box or removing its profile requests deletion of the saved password. Profile removal still clears the device and its saved viewing preferences and frees the slot if a protected password cannot be deleted; an inline notice explains that the credential was retained. Keychain operations never open an authentication dialog or offer an approval action. Manual VNC password entry remains available.

Optional clipboard sharing deliberately transfers text between your Mac and the selected server; leave it disabled if you do not want that transfer. **Find…** makes bounded connections on your chosen local network and port only when requested. Connected background computers make paced VNC requests for their RAM-only previews. Internal WebKit cards make normal website requests and use Lantern's own persistent cookies/storage. Installed-browser cards open Safari/Chrome, which retain their own profiles, settings and website sessions. Sites and browsers may have their own analytics; this is separate from Lantern's optional project-website counts.

## Why is a remembered password unavailable?

Choose Remember before connecting; its checkbox is disabled while connecting/connected, so disconnect before changing it. All Keychain operations are noninteractive. If access fails, Lantern reports it inline and leaves the VNC password field available. An unconfirmed save turns **Remember password** off and disables automatic use; a protected copy may remain. Forget also disables automatic use when deletion cannot be confirmed. There is no approval button, authentication dialog, plaintext fallback or Keychain reset.

Newly saved passwords use the fixed, signed **v2 helper** in the viewer’s existing macOS security session. Seventeen checks exercised that actual public helper with synthetic entries in the default login Keychain, without unlocking it or enabling authentication UI. Continuity depends on preserving the helper and publisher identity. Older items migrate only after an already-authorized noninteractive read. A protected synthetic v1 item was denied and left unchanged; no recovery of an owner’s older password is established. Build 14’s unreleased v1 candidate used a separate security session; its earlier private-Keychain lab did not prove default login-Keychain access.

## Does it support file transfer, audio, printing, or multiple sessions?

The current app provides display, keyboard/pointer input, optional text clipboard sharing, and internal/installed-browser cards. VNC sessions can remain connected in the background, with only the selected one controllable. It does not provide VNC file transfer, remote audio, printing, or recording. Internal WebKit downloads are unsupported; actual Safari/Chrome windows use their own browser capabilities.

## Why does macOS warn when I open the app?

Published previews use the project's self-signed publisher certificate. Development builds use ad hoc signatures. Apple Developer ID signing and notarization remain pending. Approve only a copy from a source you trust; do not disable Gatekeeper system-wide. See [Getting started](Getting-Started.md).

## Where are the source and release notes?

The [repository](https://github.com/py-killer/lantern-vnc) and matching source archive contain the app, bridge, vendor sources, build scripts, tests, and license notices. See the [changelog](../../CHANGELOG.md). Original project contributions use GPL-2.0-or-later; third-party components retain their notices. No warranty or support deadline is promised.

## How do I help?

Report a reproducible issue, improve documentation, or submit a focused fix. The [contribution guide](../../CONTRIBUTING.md) explains how to build and check a change. Optional support is a thank-you rather than a requirement.
