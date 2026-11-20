# Getting started

[Wiki home](Home.md) · [Display controls](Display-and-Navigation.md) · [Troubleshooting](Troubleshooting.md)

## What you need

- An Apple Silicon Mac running macOS 13 or later. The supplied app is an arm64 build; Intel Macs are not supported.
- A running VNC server, its reachable address and TCP port, and its VNC password if authentication is enabled.
- A trusted local network, or a VPN/SSH connection that you establish separately. This build does not encrypt the VNC transport.

The downloadable app does not need Xcode, Python, CMake, or a Lantern account. Development tools are needed only to build from source.

## Open and connect

1. Get the Mac ZIP from the [project website](https://py-killer.github.io/lantern-vnc/) and extract it. Move **Lantern VNC.app** to Applications or another folder you control.
2. Open the app. Current builds are ad hoc signed and not Apple-notarized. If macOS blocks a copy you trust, use Finder's contextual **Open** command or review the available **Open Anyway** option in Privacy & Security. Do not disable Gatekeeper system-wide.
3. If macOS asks for local network access, allow it so Lantern can reach your server.
4. Enter the server's address and TCP port. The usual port is `5900`; a server on display `:1` often uses `5901`. Enter the actual TCP port configured by your server, not the display number.
5. Enter the password configured for VNC on the server and choose **Connect**. A Windows or macOS account password is not necessarily the VNC password. Classic VNC authentication uses the first eight password bytes.
6. Start with **Auto (Readable)**. If the image is larger than the window, use its visible scroll bars or turn on **Hand** to move the local view. Choose **Fit to Window** for a whole-desktop overview. Turn Hand off and click the remote image to send keyboard and pointer input.

If the connection fails, check the [troubleshooting guide](Troubleshooting.md). Repeatedly trying a different password cannot fix an unreachable server or a blocked port.

## Save your usual devices

Choose **Save…** to save a name, server address, and port. Lantern can save up to three devices and keeps one session active at a time. Choose a saved device to restore its connection settings; use **Remove** to free a saved slot.

Passwords are not saved in device profiles. Enter the VNC password again when connecting. A full saved list does not prevent a one-off connection using the Server and Port fields.

## Before using clipboard sharing

**Share clipboard text** is optional. When enabled, text can move between your Mac and the server. Leave it off if you do not want that transfer. **View only** suppresses keyboard, pointer, and clipboard changes sent to the server; the server can also independently restrict a connection to viewing.

Choose **Disconnect** when finished. **Command–K** connects or disconnects, **Control–Command–F** toggles full screen, and **Control–Command–S** shows/hides the connection sidebar. See the [display guide](Display-and-Navigation.md) for zoom and Hand controls.

These controls are implemented in 1.1.0-preview.2. It remains a preview while physical display transitions and the manual hardware matrix are unverified.
