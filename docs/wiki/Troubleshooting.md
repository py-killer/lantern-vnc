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

Startup, automatic reconnect, and routine Keychain reads, saves, and deletions do not open a Mac-password approval dialog. If the saved password needs approval, **Use saved password…** offers an optional explicit retry that may ask for your Mac login password. That approval is separate from the remote server's VNC password. You can always enter the VNC password manually if Keychain is locked, access is denied, approval is canceled, or saving fails.

Uncheck **Remember password** to delete the saved value; **Remove** deletes the selected profile and its password. If deletion fails, Lantern reports it rather than claiming the password was removed. Keychain errors do not prevent manual connections. Lantern does not reset Keychain security or store a plaintext fallback.

## The desktop is tiny, cropped, or an edge is unreachable

In **1.1.0-preview.6**, new endpoints start in **Fit to Window** so the whole desktop is visible. Fit can make a 5K desktop's text tiny. Choose **Auto (Readable)** to avoid shrinking below 100%, or 125–200% for larger text, then use the visible scroll bars or **Hand** to reach the edges. Hand makes dragging, scrolling, and arrow keys move the local view. Press Escape or turn Hand off to resume remote input. Normal scrolling with Hand off controls the remote app.

At 100%, one remote pixel maps to one drawable/backing pixel, not one Mac point. Retina and macOS scaled display settings affect perceived text size. Local zoom never changes the server's resolution.

Zoom mode and picture preset are remembered per host and TCP port across restarts; pan positions are not. A different address or port has separate preferences. Existing saved devices can retain the old picture choice through a one-time migration, while new endpoints default to Fit and Wi-Fi · high quality.

The old 1.0 build has known large-desktop scaling/navigation issues. This preview replaces that model with a fixed viewport and shared rendering/input transform; it is not yet a fully verified stable release. Physical 1× external/2× Retina transitions and the manual hardware matrix remain untested.

Record the remote resolution, local window size, display scale, and mode. Say which edges are inaccessible and whether resizing or moving between screens triggers the issue.

## Clicks land in the wrong place

Try **Fit to Window**, then compare the remote pointer with a clearly marked test target. Note whether the offset appears after changing scale, scrolling, reconnecting, or changing the remote resolution. Include synthetic target coordinates when possible; avoid screenshots of sensitive desktops.

## The image is stale, slow, or soft

Preview 5 reduces local copying for small changes and can send queued input while a partial screen update is waiting for more data. It preserves pixel quality and the existing compression presets. It does not change VNC network compression or remove server/network delays; large full-screen changes still require full-image work.

Use **Refresh screen** to request a full update. New endpoints default to **Wi-Fi · high quality**: Tight JPEG level 8 with compression level 3. **Balanced** uses the same JPEG level with compression level 1. The higher compression request may save transfer data at a cost in server CPU; it does not promise faster updates. If the server is CPU-limited, compare Balanced using the same task after reconnecting.

**Fast** requests JPEG level 5 and compression level 1, trading picture quality for smaller JPEG updates. **Lossless** disables JPEG while retaining compression at level 1, requesting exact pixels; it can require more data for color-rich content. JPEG-enabled presets do not guarantee lossless text, and fractional local zoom can soften even lossless pixels. Try 100% when checking pixel sharpness.

Picture changes apply on the next connection and are saved for that host and port. There is no automatic quality adaptation. Remote desktop size, server update behavior, and network conditions all affect performance; shrinking the local view does not reduce the requested remote resolution. See the [preset table](FAQ.md#which-picture-preset-should-i-use-on-wi-fi).

A server reporting more than 16,384 pixels on either axis or more than 256 MiB of framebuffer data exceeds the current client limit. Clipboard messages are limited to 1 MiB.

## RTT is unavailable, idle, or low despite a slow screen

`RTT —` means macOS has no usable TCP estimate for this connection. **Idle** means no transport-counter change was observed for at least five seconds; it does not mean the connection has failed or reveal when RTT was last sampled. Normal traffic can update the kernel estimate, but polling the indicator does not send probes or request new frames.

Low RTT does not include screen capture, encoding, decoding, or rendering delay. Check server load and the picture preset rather than treating RTT as input-to-screen latency. A local SSH port forward or TCP proxy can also report a low RTT to its local endpoint while the onward route is slow. Hover over the indicator or read [its explanation](Display-and-Navigation.md#read-network-rtt).

## Connected, but keyboard or mouse input does nothing

Turn off **Hand**, click the remote image to focus it, turn off **View only**, and confirm that the server/password grants remote control. A server-issued view-only connection cannot be promoted by changing Lantern's checkbox. Try the explicit **Ctrl–Alt–Del** action for a remote secure-attention screen.

If a modifier appears stuck after a focus change, disconnect and report the key sequence. Include which Mac modifiers were held, but no sensitive text typed remotely.

## Clipboard text is missing or changed

Enable **Share clipboard text** only if you intend to transfer text. Clipboard sends are suppressed in View only mode. This is text sharing, not file or image transfer. Servers using the older Latin-1 clipboard protocol cannot represent every Unicode character; unsupported characters may become `?` unless the UTF-8 extension is negotiated.

## Prepare a helpful report

Use **Help → Save Feedback…** for a local text export, review it, and share it through the project's [issue forms](https://github.com/py-killer/lantern-vnc/issues/new/choose). Saving a file does not send it. Remove passwords, private connection details, clipboard contents, and personal desktop information. For a possible vulnerability, follow the [security policy](../../SECURITY.md).
