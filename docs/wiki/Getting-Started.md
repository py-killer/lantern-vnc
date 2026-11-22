# Getting started

[Wiki home](Home.md) · [Display controls](Display-and-Navigation.md) · [Troubleshooting](Troubleshooting.md)

## What you need

- An Apple Silicon Mac running macOS 13 or later. The supplied app is an arm64 build; Intel Macs are not supported.
- A running VNC server, its TCP port, and its VNC password if authentication is enabled. Find a nearby server in the app or enter its reachable address manually.
- A trusted local network, or a VPN/SSH connection that you establish separately. This build does not encrypt the VNC transport.

The downloadable app does not need Xcode, Python, CMake, or a Lantern account. Development tools are needed only to build from source.

## Open and connect

1. Get the Mac ZIP from the [project website](https://py-killer.github.io/lantern-vnc/) and extract it. Move **Lantern VNC.app** to Applications or another folder you control.
2. Open the app. Current builds are ad hoc signed and not Apple-notarized. If macOS blocks a copy you trust, use Finder's contextual **Open** command or review the available **Open Anyway** option in Privacy & Security. Do not disable Gatekeeper system-wide.
3. If macOS asks for local network access, allow it so Lantern can reach your server.
4. Open **Connection settings** if its fields are hidden. Set the TCP port, usually `5900`, and choose **Find…** beside Server. If one server is found, it is selected automatically. Confirm or edit its alias and choose **Save Computer** to add it to your device list immediately. If several are found, select the one you want first. You can enter a known address manually instead; **Add screen → Computer…** prepares another connection. A server on display `:1` often uses `5901`; enter its actual TCP port, not the display number.
5. Enter the password configured for VNC on the server and choose **Connect**. A Windows or macOS account password is not necessarily the VNC password. Classic VNC authentication uses the first eight password bytes. **Remember password** is off for a new endpoint; enable it only if you want macOS Keychain to save the password after a successful connection.
6. New server addresses/ports start with **Fit to Window** and **Wi-Fi · high quality**. Fit shows the whole desktop. If text is too small, choose **Auto (Readable)** or a larger zoom, then use visible scroll bars or **Hand** to move the local view. Turn Hand off and click the remote image to send keyboard and pointer input.

If the connection fails, check the [troubleshooting guide](Troubleshooting.md). Repeatedly trying a different password cannot fix an unreachable server or a blocked port.

Once connected, **RTT** appears below the connection status and refreshes once a second. It is a passive TCP round-trip estimate, not keyboard-to-screen delay. **RTT unavailable** means no usable estimate; **idle** means no traffic-counter change was observed for five seconds. Hover over it for the explanation, including local port-forwarding limits. See [Read network RTT](Display-and-Navigation.md#read-network-rtt).

## Find a local server

Search checks one selected TCP port on active private IPv4 Wi-Fi/Ethernet interfaces. Choose the network in the picker if more than one is available. It respects the subnet mask; for a subnet larger than `/24`, only the local `/24` neighborhood is searched. You can cancel, retry, or select a result as it appears. The search reads a VNC greeting and sends no authentication or credentials.

Discovery does not search VPN interfaces, IPv6, Bonjour, other ports, or public IPv4 networks. No result does not mean no server exists: check local-network permission, the port, and whether the server is reachable, or use its address manually. A result does not establish the server's identity, password, or control permissions.

## Save your usual devices

The finder saves a named device when you confirm its alias. Context-click its card for **Rename…**, or use **Save…** for a manually entered connection. A successful connection also saves a device when a slot is available, using the alias from the picker or the server's desktop name for a new profile. Lantern can save up to three computers. Select a card to restore its connection settings and control that computer; **Remove** frees its saved slot.

Connected computers keep RAM-only thumbnails, sampled about every two seconds. When another computer or a browser is selected, the previous VNC session stays connected in read-only mode with updates paced about every two seconds. Returning to that card resumes the same session. Only the selected computer receives remote input and optional clipboard sharing. **Disconnect** on a card stops that connection; switching cards alone does not disconnect it.

When the app opens, saved computers with a readable remembered password can reconnect for previews. If a password is unavailable, select the computer and connect manually. Preview ages describe the last sampled image, not a guarantee that the server is still reachable.

Passwords are not saved in device profiles. If you enable **Remember password**, Lantern attempts to save the password separately in the classic macOS login Keychain after a successful connection. Keychain synchronization is disabled. Uncheck the box to request deletion; **Remove** also requests removal of that profile's saved password. Removing a device clears its profile and saved viewing preferences and frees the slot even if the protected password cannot be deleted. An inline notice then explains that the password was retained; the protected Keychain item remains unchanged. A full saved list does not prevent a one-off connection using the Server and Port fields.

Every Keychain read, save, and deletion is noninteractive, with no authentication dialog or approval button. A failed save turns **Remember password** off. Manual VNC password entry remains available, with no plaintext fallback or Keychain security reset. Ad hoc signed app updates can lose access to earlier saved items; reliable cross-update persistence has not been verified for this preview.

## Keep your viewing preferences

The app reopens at its last normal window size and position. If the saved monitor is unavailable, it recovers placement on an available screen. This local window geometry does not change the server's resolution.

Lantern remembers zoom mode—including a custom pinch scale—and picture preset for each host and port, including after restarting the app. Pan positions are not remembered. Picture changes apply on the next connection. On the first upgrade, existing devices inherit the previous global picture preset once; afterward their settings are independent.

**Wi-Fi · high quality** requests the same JPEG level as Balanced with moderate compression that may use more server CPU. Choose **Lossless · sharp text** when JPEG artifacts are unwanted; it still uses compressed transfer. Presets do not change the server's resolution, and no preset guarantees the fastest result on every network. See [Display controls](Display-and-Navigation.md) for the exact settings.

## Add a local website

Choose **Add screen → Website…**, enter an HTTP or HTTPS address and an optional name, then choose **Add Website**. This opens a local WebKit page inside Lantern, not a website on the remote computer. Lantern's persistent website session is separate from Safari and Chrome; a site may require its own login.

Use Back, Forward, Reload, or **Command–L / R / [ / ]** while that browser screen is selected. Context-click its card to edit the address/name or remove it. Loaded pages receive sampled card previews. Up to 100 browser cards can be saved; only six pages stay loaded. Least recently used pages sleep when needed and reload on selection, which can discard unsaved page state.

Downloads are unsupported and show an inline message. HTTP authentication and credential authorization dialogs are disabled; some popup/OAuth flows need a full browser. Pages make normal network requests and can keep cookies/storage in Lantern's WebKit store. See the [browser FAQ](FAQ.md#can-i-open-websites-in-lantern).

## Before using clipboard sharing

**Share clipboard text** is optional. When enabled, text can move between your Mac and the server. Leave it off if you do not want that transfer. **View only** suppresses keyboard, pointer, and clipboard changes sent to the server; the server can also independently restrict a connection to viewing.

Choose **Disconnect** when finished. **Command–K** connects or disconnects, **Control–Command–F** toggles full screen, and **Control–Command–S** shows/hides the connection sidebar. See the [display guide](Display-and-Navigation.md) for zoom and Hand controls.

These controls are implemented in 1.2.0-preview.1. It remains a preview while physical display transitions and the manual hardware matrix are unverified.
