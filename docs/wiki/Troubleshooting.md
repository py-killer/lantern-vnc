# Troubleshooting

[Wiki home](Home.md) · [Getting started](Getting-Started.md) · [Display controls](Display-and-Navigation.md)

## Connection refused or timed out

Confirm that the VNC server is running, its current address is correct, and its firewall permits connections from your Mac. Use the TCP listening port, commonly `5900`, rather than a display number. Guest Wi-Fi isolation, an unreachable private address, or a disconnected VPN can prevent access even when both machines have internet service.

Use **Find…** to search a private Wi-Fi/Ethernet network on the selected port, or enter a known address manually. Lantern does not establish a VPN or provide a cloud relay. Establish those network routes separately.

## Find… shows no servers

Check that both computers are on a reachable network, the server is running, and Port matches its VNC listening port. Allow local-network access if macOS asks. If access was denied, review **System Settings → Privacy & Security → Local Network** when that setting is available, enable Lantern, and retry the search. Settings and prompts vary by macOS version.

Choose the correct Wi-Fi/Ethernet network in the picker. Search checks private IPv4 only, on one selected port; it does not search VPN interfaces, IPv6, Bonjour, public IPv4 networks, or all ports. For subnets larger than `/24`, only the local `/24` neighborhood is searched. Guest Wi-Fi isolation and firewalls can hide an otherwise running server. Retry after changing Wi-Fi, or enter the server's known address manually. Cancel stops the current search.

A discovered result means the endpoint returned a VNC greeting. It does not verify the server's identity, password, or control permissions. A single result is selected automatically. Confirm its alias with **Save Computer** to save the profile before connecting; this does not authenticate or save a password. A full three-device list leaves a one-off connection available without claiming that another profile was saved.

## Authentication failed

Use the VNC password configured on the server. It may differ from the computer's account password. Classic VNC authentication uses only the first eight password bytes. Confirm that the server offers compatible VNC authentication rather than a vendor cloud login or an enterprise identity method.

If a remembered password is wrong, replace the field's contents with the correct VNC password. Lantern clears the field when starting a connection and can reload a remembered password after disconnecting. A password is saved or replaced only after a successful connection with **Remember password** enabled. An authentication failure does not establish that the port is wrong. Do not post passwords in an issue or feedback file.

## Remembered password is unavailable or wrong

Passwords are separate from device profiles and keyed by host and TCP port. A different address or port is a different saved endpoint. Selecting a saved device loads its remembered password silently if Keychain allows it; editing the endpoint clears the previous credential.

Choose **Remember password** before Connect. The checkbox is disabled during connection attempts and connected sessions; disconnect before changing it. Every Keychain read, save, and deletion is noninteractive. Failures appear inline. An unconfirmed save turns **Remember password** off and disables automatic use; a protected copy may still remain. The app offers no approval action or Keychain authentication dialog. Manual VNC entry remains available.

Disconnect first, then uncheck **Remember password** to request deletion; **Remove** also requests deletion of the saved password. Automatic use remains disabled even when deletion cannot be confirmed, and an inline notice explains that a protected copy may remain. Profile removal still clears the device and its viewing preferences and frees the slot.

Build 15 uses a fixed, signed **v2 helper** that joins the viewer’s existing security session. Seventeen checks exercised the actual public helper against synthetic entries in the default login Keychain without unlocking it or enabling authentication UI. The unreleased build 14 helper instead started in a separate security session; its private-Keychain lab did not prove this normal login-Keychain path. Updates must preserve the v2 helper and publisher identity. Older items are read only when macOS already permits a silent read; a protected synthetic v1 item was denied and left unchanged. Manual VNC entry can save a new v2 entry after a successful connection. The helper does not reset Keychain security or recover inaccessible old items.

## The desktop is tiny, cropped, or an edge is unreachable

In **1.2.0-preview.2**, new endpoints start in **Fit to Window** so the whole desktop is visible. Fit can make a 5K desktop's text tiny. Choose **Auto (Readable)** to avoid shrinking below 100%, or 125–200% for larger text, then use the visible scroll bars or **Hand** to reach the edges. Hand makes dragging, scrolling, and arrow keys move the local view. Press Escape or turn Hand off to resume remote input. Normal scrolling with Hand off controls the remote app.

At 100%, one remote pixel maps to one drawable/backing pixel, not one Mac point. Retina and macOS scaled display settings affect perceived text size. Local zoom never changes the server's resolution.

Zoom mode and picture preset are remembered per host and TCP port across restarts; pan positions are not. A different address or port has separate preferences. Existing saved devices can retain the old picture choice through a one-time migration, while new endpoints default to Fit and Wi-Fi · high quality.

The old 1.0 build has known large-desktop scaling/navigation issues. This preview replaces that model with a fixed viewport and shared rendering/input transform; it is not yet a fully verified stable release. Physical 1× external/2× Retina transitions and the manual hardware matrix remain untested.

Record the remote resolution, local window size, display scale, and mode. Say which edges are inaccessible and whether resizing or moving between screens triggers the issue.

The app remembers its last normal window size and position. When reopened without the previous monitor, it recovers offscreen placement onto an available screen, so the restored size or position may differ. Window geometry is separate from per-host Fit/zoom settings and does not change the server's resolution. Physical display-transition coverage remains incomplete.

## Clicks land in the wrong place

Try **Fit to Window**, then compare the remote pointer with a clearly marked test target. Note whether the offset appears after changing scale, scrolling, reconnecting, or changing the remote resolution. Include synthetic target coordinates when possible; avoid screenshots of sensitive desktops.

## The image is stale, slow, or soft

Card previews are sampled, not live video. Background VNC sessions are read-only with requests paced roughly every ten seconds. The selected screen stops repeated thumbnail sampling after an initial image; its main desktop/browser still runs normally. Select a computer to resume foreground updates on its existing connection. A disconnected card can retain a labeled last capture; its image does not prove that the server is reachable. Thumbnails stay in RAM and are not saved screenshots. Selecting a live card does not move it. Offline, sleeping or closing cards move to the bottom and regain their original live-card position when available again.

Preview 5 reduces local copying for small changes and can send queued input while a partial screen update is waiting for more data. It preserves pixel quality and the existing compression presets. It does not change VNC network compression or remove server/network delays; large full-screen changes still require full-image work.

Use **Refresh screen** to request a full update. New endpoints default to **Wi-Fi · high quality**: Tight JPEG level 8 with compression level 3. **Balanced** uses the same JPEG level with compression level 1. The higher compression request may save transfer data at a cost in server CPU; it does not promise faster updates. If the server is CPU-limited, compare Balanced using the same task after reconnecting.

**Fast** requests JPEG level 5 and compression level 1, trading picture quality for smaller JPEG updates. **Lossless** disables JPEG while retaining compression at level 1, requesting exact pixels; it can require more data for color-rich content. JPEG-enabled presets do not guarantee lossless text, and fractional local zoom can soften even lossless pixels. Try 100% when checking pixel sharpness.

Picture changes apply on the next connection and are saved for that host and port. There is no automatic quality adaptation. Remote desktop size, server update behavior, and network conditions all affect performance; shrinking the local view does not reduce the requested remote resolution. See the [preset table](FAQ.md#which-picture-preset-should-i-use-on-wi-fi).

A server reporting more than 16,384 pixels on either axis or more than 256 MiB of framebuffer data exceeds the current client limit. Clipboard messages are limited to 1 MiB.

## RTT is unavailable, idle, or low despite a slow screen

**RTT unavailable** means macOS has no usable TCP estimate for this connection. **Idle** means no transport-counter change was observed for at least five seconds; it does not mean the connection has failed or reveal when RTT was last sampled. Normal traffic can update the kernel estimate, but polling the indicator does not send probes or request new frames.

Low RTT does not include screen capture, encoding, decoding, or rendering delay. Check server load and the picture preset rather than treating RTT as input-to-screen latency. A local SSH port forward or TCP proxy can also report a low RTT to its local endpoint while the onward route is slow. Hover over the indicator or read [its explanation](Display-and-Navigation.md#read-network-rtt).

## Connected, but keyboard or mouse input does nothing

Select the computer's card first: browser screens and background computer previews never send it input. Turn off **Hand**, click the remote image to focus it, turn off **View only**, and confirm that the server/password grants remote control. A server-issued view-only connection cannot be promoted by changing Lantern's checkbox. Try the explicit **Ctrl–Alt–Del** action for a remote secure-attention screen.

If a modifier appears stuck after a focus change, disconnect and report the key sequence. Include which Mac modifiers were held, but no sensitive text typed remotely.

## Clipboard text is missing or changed

Enable **Share clipboard text** only if you intend to transfer text. Clipboard sends are suppressed in View only mode. This is text sharing, not file or image transfer. Servers using the older Latin-1 clipboard protocol cannot represent every Unicode character; unsupported characters may become `?` unless the UTF-8 extension is negotiated.

## A browser page is sleeping, cannot load, or loses its form

For **Lantern · inside this window**, each card contains up to 12 WebKit tabs; change pages using its tab strip rather than another sidebar card. Closing the last tab leaves a fresh new tab. Popup links stay in that internal window as new tabs. Existing one-address cards migrate into internal one-tab windows with their aliases and URLs preserved.

Only six internal WebKit windows stay loaded. A least recently used inactive internal window sleeps when another needs its slot; selecting that card restores its saved tabs/selection and loads pages on demand, so unsaved forms or page state may be lost. Up to 100 browser cards can remain recorded. Removing an internal window stops its loaded tabs; switching away alone leaves loaded tabs running with about ten-second background previews. Removing an installed Safari/Chrome card does not close that actual browser.

Check the selected internal tab's HTTP(S) address and use inline **Retry** after a network failure. While a tab is loading, the Reload button becomes **Stop**. Stop cancels only that tab's pending load and keeps the requested address so Reload can try it again; Command–R always reloads. Use the address field or context-click **Edit…** on the card to correct its selected address or window name. The internal browser shortcuts do not target a VNC computer.

Internal WebKit downloads are unsupported and reported inline; its HTTP authentication and credential authorization dialogs are disabled. Use an installed Safari/Chrome card for extension-dependent or full-browser workflows. These cards open the real external app with its own profile, not an embedded copy. First explicit selection opens the saved URL; later selection activates the running app. **Open Website** opens the address again deliberately, and **Change URL…** edits it. Restoring Lantern does not auto-launch an external browser. The app cannot guarantee which browser window, tab or profile becomes frontmost.

## A website shows verification or keeps loading

A page titled **百度安全验证** is Baidu's website verification content, not a VNC-password error. In owned diagnostics, Baidu's homepage loaded normally. Eight search-navigation cases across raw WebKit and Lantern, HTTP/HTTPS, and default/Safari-like user agents ended on Baidu's verification page with HTTP 200 and WebKit reporting `isLoading == false`; the resulting content appeared blank. This reproduced the verification redirect, not every report of a permanently busy page, and does not establish why the site chose verification.

Use **Stop** if the selected internal tab is still loading, then Reload to retry its intended address. If the verification page or blank result persists, try that address through an **installed Safari or Google Chrome** card, choose your normal profile there, and complete the site's ordinary verification if offered. Existing browser cookies, logins or extensions are not imported into Lantern WebKit. A real-browser choice is not a verification bypass and does not guarantee the site will stop asking.

## Prepare a helpful report

Use **Help → Save Feedback…** for a local text export, review it, and share it through the project's [issue forms](https://github.com/py-killer/lantern-vnc/issues/new/choose). Saving a file does not send it. Remove passwords, private connection details, clipboard contents, and personal desktop information. For a possible vulnerability, follow the [security policy](../../SECURITY.md).
