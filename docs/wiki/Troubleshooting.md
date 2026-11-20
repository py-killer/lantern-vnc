# Troubleshooting

[Wiki home](Home.md) · [Getting started](Getting-Started.md) · [Display controls](Display-and-Navigation.md)

## Connection refused or timed out

Confirm that the VNC server is running, its current address is correct, and its firewall permits connections from your Mac. Use the TCP listening port, commonly `5900`, rather than a display number. Guest Wi-Fi isolation, an unreachable private address, or a disconnected VPN can prevent access even when both machines have internet service.

Lantern does not discover computers, establish a VPN, or provide a cloud relay. Establish the network route separately. If macOS previously denied local network permission, review the app's permission in System Settings.

## Authentication failed

Use the VNC password configured on the server. It may differ from the computer's account password. Classic VNC authentication uses only the first eight password bytes. Confirm that the server offers compatible VNC authentication rather than a vendor cloud login or an enterprise identity method.

Enter the password again after a failed attempt; Lantern clears the field when starting a connection. Do not post it in an issue or feedback file.

## The desktop is tiny, cropped, or an edge is unreachable

In **1.1.0-preview.1**, use **Auto (Readable)** to avoid shrinking below 100%, then use the visible scroll bars or **Hand** to reach the edges. Hand makes dragging, scrolling, and arrow keys move the local view. Press Escape or turn Hand off to resume remote input. Choose **Fit to Window** for an overview, or 125–200% when text needs to be larger. Normal scrolling with Hand off controls the remote app.

At 100%, one remote pixel maps to one drawable/backing pixel, not one Mac point. Retina and macOS scaled display settings affect perceived text size. Local zoom never changes the server's resolution.

The old 1.0 build has known large-desktop scaling/navigation issues. This preview replaces that model with a fixed viewport and shared rendering/input transform; it is not yet a fully verified stable release. Physical 1× external/2× Retina transitions and the manual hardware matrix remain untested.

Record the remote resolution, local window size, display scale, and mode. Say which edges are inaccessible and whether resizing or moving between screens triggers the issue.

## Clicks land in the wrong place

Try **Fit to Window**, then compare the remote pointer with a clearly marked test target. Note whether the offset appears after changing scale, scrolling, reconnecting, or changing the remote resolution. Include synthetic target coordinates when possible; avoid screenshots of sensitive desktops.

## The image is stale, slow, or soft

Use **Refresh screen** to request a full update. Picture quality is selected before connecting: choose Lossless for text without JPEG artifacts, Balanced for general use, or Fast when bandwidth is constrained. Remote desktop size, server update behavior, and network conditions all affect performance. Metal rendering does not remove those limits.

A server reporting more than 16,384 pixels on either axis or more than 256 MiB of framebuffer data exceeds the current client limit. Clipboard messages are limited to 1 MiB.

## Connected, but keyboard or mouse input does nothing

Turn off **Hand**, click the remote image to focus it, turn off **View only**, and confirm that the server/password grants remote control. A server-issued view-only connection cannot be promoted by changing Lantern's checkbox. Try the explicit **Ctrl–Alt–Del** action for a remote secure-attention screen.

If a modifier appears stuck after a focus change, disconnect and report the key sequence. Include which Mac modifiers were held, but no sensitive text typed remotely.

## Clipboard text is missing or changed

Enable **Share clipboard text** only if you intend to transfer text. Clipboard sends are suppressed in View only mode. This is text sharing, not file or image transfer. Servers using the older Latin-1 clipboard protocol cannot represent every Unicode character; unsupported characters may become `?` unless the UTF-8 extension is negotiated.

## Prepare a helpful report

Use **Help → Save Feedback…** for a local text export, review it, and share it through the project's [issue forms](https://github.com/py-killer/lantern-vnc/issues/new/choose). Saving a file does not send it. Remove passwords, private connection details, clipboard contents, and personal desktop information. For a possible vulnerability, follow the [security policy](../../SECURITY.md).
