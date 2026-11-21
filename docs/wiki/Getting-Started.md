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
4. Set the TCP port, usually `5900`, and choose **Find…** beside Server. If one server is found, it is selected automatically. Confirm or edit its alias and choose **Save Computer** to add it to your device list immediately. If several are found, select the one you want first. You can enter a known address manually instead. A server on display `:1` often uses `5901`; enter its actual TCP port, not the display number.
5. Enter the password configured for VNC on the server and choose **Connect**. A Windows or macOS account password is not necessarily the VNC password. Classic VNC authentication uses the first eight password bytes. **Remember password** is off for a new endpoint; enable it only if you want macOS Keychain to save the password after a successful connection.
6. Start with **Auto (Readable)**. If the image is larger than the window, use its visible scroll bars or turn on **Hand** to move the local view. Choose **Fit to Window** for a whole-desktop overview. Turn Hand off and click the remote image to send keyboard and pointer input.

If the connection fails, check the [troubleshooting guide](Troubleshooting.md). Repeatedly trying a different password cannot fix an unreachable server or a blocked port.

## Find a local server

Search checks one selected TCP port on active private IPv4 Wi-Fi/Ethernet interfaces. Choose the network in the picker if more than one is available. It respects the subnet mask; for a subnet larger than `/24`, only the local `/24` neighborhood is searched. You can cancel, retry, or select a result as it appears. The search reads a VNC greeting and sends no authentication or credentials.

Discovery does not search VPN interfaces, IPv6, Bonjour, other ports, or public IPv4 networks. No result does not mean no server exists: check local-network permission, the port, and whether the server is reachable, or use its address manually. A result does not establish the server's identity, password, or control permissions.

## Save your usual devices

The finder saves a named device when you confirm its alias. Use **Rename…** for an existing saved device, or **Save…** for a manually entered connection. A successful connection also saves a device when a slot is available, using the alias from the picker or the server's desktop name for a new profile. Lantern can save up to three devices and keeps one session active at a time. Choose a saved device to restore its connection settings; use **Remove** to free a saved slot.

Passwords are not saved in device profiles. If you enable **Remember password**, the password is saved separately in the classic macOS login Keychain after a successful connection and can be loaded for the same host and port. Keychain synchronization is disabled. Uncheck the box to delete that saved password; **Remove** deletes both the selected profile and its saved password. If Keychain access is denied or unavailable, enter the password manually. A full saved list does not prevent a one-off connection using the Server and Port fields.

## Before using clipboard sharing

**Share clipboard text** is optional. When enabled, text can move between your Mac and the server. Leave it off if you do not want that transfer. **View only** suppresses keyboard, pointer, and clipboard changes sent to the server; the server can also independently restrict a connection to viewing.

Choose **Disconnect** when finished. **Command–K** connects or disconnects, **Control–Command–F** toggles full screen, and **Control–Command–S** shows/hides the connection sidebar. See the [display guide](Display-and-Navigation.md) for zoom and Hand controls.

These controls are implemented in 1.1.0-preview.3. It remains a preview while physical display transitions and the manual hardware matrix are unverified.
