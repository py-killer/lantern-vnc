# Lantern VNC 1.1.0-preview.1

A free native VNC viewer for Apple Silicon Macs, built with AppKit and Metal.
Connect directly to a TightVNC server, view its desktop, and control it with
your Mac's keyboard and mouse. No browser, account, subscription, or license
key is required. This version has no expiry, trial clock, license check, or
paid feature unlock. Optional tips and feedback never affect access.

**Preview candidate:** this update replaces the 1.0 display/navigation model,
which had large-desktop scaling and edge-navigation issues. The new controls
are implemented locally, but physical external-display transitions and the
complete manual hardware matrix have not been verified. Treat this as a
preview, not a fully checked stable release.

[Project website](https://py-killer.github.io/lantern-vnc/) ·
[Source repository](https://github.com/py-killer/lantern-vnc) ·
[Send feedback](https://github.com/py-killer/lantern-vnc/issues/new/choose) ·
[Wiki](docs/wiki/Home.md) · [Changelog](CHANGELOG.md) ·
[Release checklist](docs/RELEASE_CHECKLIST.md) ·
[Preview test results](docs/TEST_RESULTS-1.1.0-preview.1.md)

## Open the app

Requirements: macOS 13 or later and an Apple Silicon Mac (M1 through M5 and
other compatible Apple Silicon models). The app is an arm64 build. It does
not support Intel Macs. Python, Node.js, CMake, and Xcode are not required to
run the supplied app.

1. Extract `Lantern-VNC-macOS.zip` and move `Lantern VNC.app` to Applications
   or another folder you control.
2. Open `Lantern VNC.app`. This development build is ad hoc signed and has
   not been Apple-notarized. If macOS blocks it, use Finder's contextual
   **Open** command, or review the app in **System Settings → Privacy &
   Security → Open Anyway** if that option appears. Only approve a copy from
   a source you trust. Do not disable Gatekeeper system-wide.
3. If macOS requests access to the local network, allow it so the app can
   reach your server.
4. Leave Server at `192.168.0.101` and Port at `5900`, or enter your own VNC
   host and TCP port. Enter the **VNC password configured in TightVNC** and
   choose **Connect**. The port field is a TCP port, not a VNC display number.

Classic VNC password authentication uses only the first eight password bytes.
An account password for Windows or macOS is not necessarily your VNC password.
The app does not require a Lantern account.

## Use the remote desktop

The default **Auto (Readable)** mode avoids shrinking a large remote desktop
below 100%. Use the zoom menu, visible scroll bars, or **Hand** to navigate.
Lantern changes your local view; it never changes the server's resolution.

| Control | Behavior |
| --- | --- |
| **Auto (Readable)** | Uses `max(100%, min(Fit zoom, 200%))` in drawable/backing pixels. A large 5K desktop stays at 100% and is navigable rather than being shrunk to fit. |
| **Fit to Window** | Shows the whole desktop with its aspect ratio preserved. Text may be small on a large remote desktop. |
| **50%, 75%, 100%, 125%, 150%, 200%** | Explicit local zoom. At 100%, one remote pixel maps to one Metal drawable/backing pixel. macOS scaled display modes may resample the final panel image. |
| **Pinch** | Sets a custom local zoom between 10% and 400%. |
| **Hand** | Drag, scroll, or use arrow keys to move the local view. Press Escape or turn Hand off to resume remote control. |
| **Native scroll bars** | Stay visible on each axis where the image is larger than the viewport. |
| **Sidebar button / Control–Command–S** | Hide or show connection settings to make more room for the desktop. |

With Hand off, click inside the remote image to type and control the pointer;
normal wheel/trackpad scrolling is sent to the remote computer. Hand is a
local navigation mode and does not send remote clicks, typing, or wheel
input.

**Control–Command–+ / −** zoom in/out; **Control–Command–0** selects 100%.
**Control–Command–F** toggles full screen, and **Command–K** connects or
disconnects. The sidebar is hidden on entering full screen and restored when
leaving it.

**View only** suppresses keyboard, pointer, and clipboard changes sent to the
server. Optional **Map Command to Control** helps with Windows/Linux
shortcuts. **Ctrl–Alt–Del**, **Clipboard**, and **Refresh screen** remain
explicit toolbar actions. **Share clipboard text** enables optional two-way
text transfer.

See [Display and navigation](docs/wiki/Display-and-Navigation.md) for the
viewing model and [Troubleshooting](docs/wiki/Troubleshooting.md) for common
connection, display, and input problems.

Choose **Balanced** for everyday LAN use, **Lossless** for sharp text without
JPEG compression, or **Fast** when bandwidth is limited. Picture quality is
chosen before connecting. Display performance depends on the server, remote
screen size, and network; the renderer uses Metal and the JPEG decoder uses
Apple Silicon SIMD.

Save up to three device profiles to switch between your usual servers. Device
settings are stored locally on your Mac. Passwords are not stored in saved
profiles; enter the VNC password for each session. One remote session is
active at a time.

## Optional support and feedback

The app's feedback command opens the project's GitHub issue form in your
browser. GitHub may require its own sign-in to submit an issue; that account
is optional and is never required to run Lantern VNC. Feedback is submitted
only when you choose to send it. Do not post VNC passwords or private network
details in a public issue.

Use **Help → Save Feedback…** to write a local text file containing your notes,
app version, macOS version, GPU name, and renderer name. The app does not
automatically add a server address, password, clipboard contents, or network
credentials. Review your own notes before sharing the file. Saving feedback
does not send it anywhere.

The support command opens the website's
[support section](https://py-killer.github.io/lantern-vnc/#support). Tipping is
optional. No payment destination is configured in this development build,
and the app does not collect payments or financial details. Every feature
of this version remains available without a tip.

## Privacy and network security

Lantern VNC connects directly to the selected server. It has no account
service, analytics, cloud relay, or licensing server. Saved server settings
stay in the app's local preferences. VNC passwords stay in process memory
for connection setup and are not written to disk by the app. Enabling
clipboard sharing transfers clipboard text between your Mac and the server;
leave it disabled if you do not want that transfer.

This build does **not encrypt the VNC transport** and does not implement an
SSH tunnel. Use it on a network you trust or through a separately established
VPN/SSH tunnel. Do not expose an unencrypted TightVNC service directly to the
internet. The server decides whether a connection permits remote control.

## Troubleshooting

- **Cannot connect / connection refused:** confirm TightVNC Server is running,
  the server's current address is correct, its VNC listening port is `5900`
  (or the value you entered), and the firewall allows that connection.
- **Connection timed out:** put both devices on a reachable LAN or VPN. Guest
  Wi-Fi isolation and a changed server address can prevent access.
- **Authentication failed:** check the TightVNC VNC password and whether the
  server offers standard VNC password authentication. This build does not
  provide RealVNC cloud login or enterprise identity authentication.
- **Connected but input does nothing:** turn off Hand, disable View only, and confirm the
  server account/password grants control. A view-only TightVNC password
  remains view-only even when the app's checkbox is off.
- **Desktop edges are out of view:** use the visible scroll bars or Hand. Use
  Fit to Window for an overview, or a larger explicit zoom for readable text.
- **Screen looks stale:** request a full update with Refresh screen.

This is a focused desktop viewer, with no audio, file transfer, printing,
recording, cloud address book, or unattended relay service. It does not aim
to duplicate every feature of a commercial remote-access suite. Remote
framebuffers are limited to 16,384 pixels per axis and 256 MiB total memory.

### Preview verification limits

The fixed Metal viewport, shared render/input transform, explicit zoom, and
Hand navigation are implemented in this candidate. Automated geometry,
protocol, and synthetic native GPU checks do not replace manual checks on a
real server and physical displays. Moving between 1× external and 2× Retina
displays, external-monitor disconnect/reconnect, macOS scaled display modes,
and the full manual resolution/window matrix remain unverified. See the
[release checklist](docs/RELEASE_CHECKLIST.md); unchecked cases are not passes.

## Build from source

The matching source is in `Lantern-VNC-source.zip`. It includes the Swift
application, C bridge, complete LibVNCServer 0.9.15 and libjpeg-turbo 3.2.1
source trees, original license notices, tests, build scripts, wiki, and
community guidance.

Building requires an Apple Silicon Mac, the Xcode command-line tools
(`xcrun clang` and `xcrun swiftc`), and CMake 3.16 or later available on PATH.
No dependency download is required when using the complete source archive.
From the extracted source folder:

```sh
./scripts/build-deps.sh
./scripts/build-app.sh
open "build/Lantern VNC.app"
```

If CMake is installed outside PATH, set `CMAKE_BIN` to its executable. The
build uses arm64, macOS 13 as the deployment target, static LibVNCClient and
libjpeg-turbo, and the macOS system zlib. The icon is included; regenerate
its original vector artwork with:

```sh
xcrun swift -module-cache-path build/module-cache scripts/make-icon.swift
```

Run the local mock-server integration tests with Python 3:

```sh
./tests/run-tests.sh
TEST_SANITIZE=1 ./tests/run-tests.sh
./tests/run-display-tests.sh
./tests/run-app-ui-tests.sh
```

The protocol tests cover decoded pixels, remote resizing, input/clipboard
messages, view-only suppression, authentication failures, cancellation,
connection errors, and repeated cleanup. The display test script checks
viewport geometry and an owned offscreen native window with synthetic
frames and events. It does not send input to a real remote desktop. If Metal
or WindowServer is unavailable, that native harness reports exit 77 rather
than a passing result.

Physical display switching, real-server usability, and manual gestures need
the separate [release checklist](docs/RELEASE_CHECKLIST.md). A successful
login to a real TightVNC server still requires its password and a reachable
network.

To rebuild the app and create the app/source distribution archives (also
requires Python 3 for source staging):

```sh
./scripts/package.sh
```

The package script writes to `../outputs` by default; an absolute output
directory can be passed as its first argument. It verifies the ad hoc code
signature and bundles the license notices. Ad hoc signing permits local
integrity checks and is not Apple Developer ID signing or notarization.
Apple Developer ID signing and Apple notarization are pending. This package
uses ad hoc signing, and macOS may require you to approve opening it.

## Community

See [Contributing](CONTRIBUTING.md), the [code of conduct](CODE_OF_CONDUCT.md),
and the [security policy](SECURITY.md). Issues and pull requests are public;
review notes and screenshots before sharing them.

## License and acknowledgments

Lantern VNC's application code, wrapper, scripts, and original icon artwork
are provided under GNU GPL version 2 or, at your option, any later version.
See `LICENSE` and `THIRD_PARTY_NOTICES.md`. There is no warranty. Keep the
matching source archive and licenses available when redistributing the app.
The free current version does not depend on donations or a subscription.

This software is based in part on the work of the Independent JPEG Group.
