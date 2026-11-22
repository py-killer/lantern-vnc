# Lantern VNC — free VNC client for Mac

**Release candidate: 1.2.0-preview.2 · build 15 · Apple Silicon · macOS 13+**

A free native VNC client for Apple Silicon Macs, built with AppKit and Metal.
Use it for an occasional remote task or regular direct access to your existing VNC server.
Connect directly to a TightVNC server, view its desktop, and control it with
your Mac's keyboard and mouse. No external browser, Lantern account, subscription, or license
key is required. This version has no expiry, trial clock, license check, or
paid feature unlock. Optional tips and feedback never affect access.

**Preview candidate:** this update adds named screen cards, background VNC
previews, and local browser screens to the existing Metal viewer. The workspace
has owned-fixture integration coverage, but physical external-display transitions and the
complete manual hardware matrix have not been verified. Treat this as a
preview, not a fully checked stable release.

[Project website](https://py-killer.github.io/lantern-vnc/) ·
[Mac VNC client guide](https://py-killer.github.io/lantern-vnc/mac-vnc-client.html) ·
[Occasional-access guide](https://py-killer.github.io/lantern-vnc/occasional-vnc-access.html) ·
[Source repository](https://github.com/py-killer/lantern-vnc) ·
[Community and feedback](COMMUNITY.md) ·
[Wiki](docs/wiki/Home.md) · [Changelog](CHANGELOG.md) ·
[Release checklist](docs/RELEASE_CHECKLIST.md) ·
[Preview 2 test results](docs/TEST_RESULTS-1.2.0-preview.2.md) ·
[Earlier 1.2 Preview 1 test results](docs/TEST_RESULTS-1.2.0-preview.1.md) ·
[Earlier Preview 6 results](docs/TEST_RESULTS-1.1.0-preview.6.md) ·
[Earlier Preview 5 results](docs/TEST_RESULTS-1.1.0-preview.5.md) ·
[Earlier Preview 4 results](docs/TEST_RESULTS-1.1.0-preview.4.md)

## Open the app

Requirements: macOS 13 or later and an Apple Silicon Mac (M1 through M5 and
other compatible Apple Silicon models). The app is an arm64 build. It does
not support Intel Macs. Python, Node.js, CMake, and Xcode are not required to
run the supplied app.

1. Extract `Lantern-VNC-macOS.zip` and move `Lantern VNC.app` to Applications
   or another folder you control.
2. Open `Lantern VNC.app`. The published preview uses the project's self-signed
   publisher certificate. Apple Developer ID signing and notarization remain
   pending. If macOS blocks it, use Finder's contextual
   **Open** command, or review the app in **System Settings → Privacy &
   Security → Open Anyway** if that option appears. Only approve a copy from
   a source you trust. Do not disable Gatekeeper system-wide.
3. If macOS requests access to the local network, allow it so the app can
   reach your server.
4. Choose **Find…** beside Server to search your local Wi-Fi or Ethernet
   network. A lone result is selected automatically; otherwise select one.
   Confirm or edit its alias and choose **Save Computer**. You can also enter
   a known host and TCP port manually. The usual port is `5900`; the field
   takes a TCP port, not a VNC display number.
5. Enter the **VNC password configured in TightVNC** and choose **Connect**.
   **Remember password** is off for a new endpoint. Enable it only if you want
   the password saved in macOS Keychain after a successful connection.

Classic VNC password authentication uses only the first eight password bytes.
An account password for Windows or macOS is not necessarily your VNC password.
The app does not require a Lantern account.

**Find…** checks only the selected port on private IPv4 Wi-Fi/Ethernet
interfaces. It respects the subnet mask and limits larger networks to the
local `/24` neighborhood. It reads the VNC greeting without authenticating
or sending credentials. Search can be canceled or retried; a result confirms
a VNC greeting, not that your password or remote-control permissions work.
VPN interfaces, IPv6, Bonjour, and other ports are not automatically searched.
Use a manual address for those setups or when no result appears.

## Use the remote desktop

The sidebar shows named cards for up to three saved VNC computers. Select a
card to control that computer; **Connection settings** reveals its host, port,
and connection options. Connected computers keep small, aspect-correct previews
in RAM. Background connections become read-only, with preview requests and
samples about every ten seconds. The selected screen gets an initial thumbnail,
then repeated thumbnail work pauses while its main view continues at normal
speed. Selecting a connected card
resumes its existing session; only the selected computer receives remote input
or optional clipboard sharing. Context-click a card to rename, disconnect, or
remove it. Previews are not saved to disk.

Live and connecting cards keep their saved order. Selecting a card does not
move it. Offline, sleeping, or closing screens move to the bottom; when they
become live again, their original position among live cards is restored.

New server addresses/ports start in **Fit to Window**, showing the whole
desktop. If text is too small, choose **Auto (Readable)** or a larger zoom,
then use the visible scroll bars or **Hand** to navigate. Lantern remembers
the zoom mode, including custom pinch scale, for each host and port across
restarts. Pan positions are not remembered. These controls change your local
view; they never change the server's resolution.

| Control | Behavior |
| --- | --- |
| **Fit to Window** | Default for a new endpoint. Shows the whole desktop with its aspect ratio preserved. Text may be small on a large remote desktop. |
| **Auto (Readable)** | Uses `max(100%, min(Fit zoom, 200%))` in drawable/backing pixels. A large 5K desktop stays at 100% and can be navigated with scroll bars or Hand. |
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

Lantern remembers the last normal window size and position when you reopen
the app. If its saved monitor is unavailable, placement is recovered onto an
available screen. This local window geometry is separate from the saved
Fit/zoom and picture preset for each host and port; it does not change the
server's resolution.

**View only** suppresses keyboard, pointer, and clipboard changes sent to the
server. Optional **Map Command to Control** helps with Windows/Linux
shortcuts. **Ctrl–Alt–Del**, **Clipboard**, and **Refresh screen** remain
explicit toolbar actions. **Share clipboard text** enables optional two-way
text transfer.

See [Display and navigation](docs/wiki/Display-and-Navigation.md) for the
viewing model and [Troubleshooting](docs/wiki/Troubleshooting.md) for common
connection, display, and input problems.

**Wi-Fi · high quality** is the default picture preset for a new endpoint.
It requests the same Tight JPEG level 8 as **Balanced · fast LAN**, with
moderate compression level 3 instead of 1. This can trade more server CPU
for fewer transferred bytes; it does not guarantee faster performance.
**Fast · lower bandwidth** requests JPEG level 5 and compression 1.
**Lossless · sharp text** keeps compression enabled at level 1 and disables
JPEG for exact decoded pixels. JPEG-enabled presets can introduce text
artifacts; the coarse levels are not quality percentages.

Picture presets are saved per host and port and apply on the next connection.
On the first upgrade, the former global picture preset is copied to existing
devices; later changes are independent for each endpoint. Performance depends
on the server, remote screen size, and network. The renderer uses Metal and
the JPEG decoder uses Apple Silicon SIMD; there is no automatic bandwidth or
quality adaptation.

Preview 5 copies and uploads changed parts of the decoded desktop instead
of repeatedly copying the entire image for small updates. Each display
buffer keeps the changes it still needs. Queued keyboard and pointer input
can also be sent while an incomplete screen update waits for more data.
These local changes preserve decoded pixels, picture presets, and server
resolution; they do not change VNC compression or guarantee faster Wi-Fi.
Full-screen changes still require full-image work. The recorded copy
benchmark measures local CPU work, not network or end-to-end performance.

While connected, **RTT** appears below the connection status and refreshes
once a second. It is macOS's smoothed TCP round-trip estimate for the current
connection, not input-to-screen delay. **RTT unavailable** means no usable estimate is
available. **Idle** appears after five seconds without an observed transport
counter change; that activity age is not the age of the RTT sample. Polling
does not send extra probes, input, or screen-update requests, or add analytics.
Low RTT can still accompany slow capture, encoding, decoding, or rendering.
With a local SSH port forward, it can describe the local forwarding endpoint
rather than the remote computer. Picture quality and rendering are unchanged.

Save up to three device profiles to switch between your usual servers. Device
settings are stored locally on your Mac. The finder saves a device when you
confirm its alias. Choose **Rename…** to change a saved name or **Save…** for
a manually entered device; a successful manual connection also saves it when
a slot is available, using the server's desktop name. Passwords are stored separately
in macOS Keychain only when you opt in and saving succeeds. Disconnect first, then uncheck **Remember
password** to request deletion for that host and port; **Remove** also requests
deletion of the selected profile's saved password. Removing a device still clears
its profile and saved viewing preferences and frees the slot if that password
cannot be deleted; an inline notice explains that the protected credential was
retained. Saved computers can remain connected in the background, with one
selected for control. A full saved list still permits
a one-off connection.

Choose **Remember password** before connecting. It is disabled while connecting
or connected; disconnect before changing it or requesting Forget.

All Keychain reads, saves, and deletions are noninteractive. Lantern never
opens a Keychain authentication dialog or offers an approval action. Errors
appear inline. Unconfirmed saving turns **Remember password** off and disables
automatic use; a protected copy may still remain. Forget disables automatic use
even if deletion cannot be confirmed. Inaccessible existing items remain unchanged. Manual VNC password entry stays available;
the app does not use plaintext fallback storage or reset Keychain security.

Newly saved passwords use the fixed, signed **v2 credential helper**, which joins
the viewer's existing macOS security session. Seventeen checks exercised the
actual public v2 helper against UUID-named synthetic entries in the default login
Keychain, without unlocking it or enabling authentication UI. These checks cover
new entries and do not use or establish access to an owner's saved password.
Continuity depends on preserving the signed helper and publisher identity.

Build 14 was an unreleased internal candidate: its v1 helper started in a separate
security session, so the earlier private-Keychain lab did not establish normal
login-Keychain access. Build 15 uses a separate v2 service and storage namespace;
the old helper and protected v1 items are preserved.

**Legacy limitation:** an older Keychain item migrates only if macOS already
allows its noninteractive read. Inaccessible older items remain protected; the
helper does not recover them or bypass their access controls. Manual VNC entry
can create a newly remembered vault entry after a successful connection. The
synthetic proof does not establish migration of every earlier saved password.

## Choose a browser for a card

Choose **Add screen → Browser window…**. **Lantern · inside this window** is selected by default; choose another browser explicitly if needed:

| Choice | Where it opens | Session and extensions |
| --- | --- | --- |
| **Lantern · inside this window** | A tabbed WebKit window inside Lantern | Lantern's own website storage, separate from Safari/Chrome. Installed browser extensions are not imported. |
| **Safari · opens outside Lantern** | Your actual Safari app, outside Lantern | Safari manages its existing profile, logins and enabled extensions. |
| **Google Chrome · opens outside Lantern** | Your actual Chrome app, outside Lantern | Chrome manages its existing profile, logins and enabled extensions, including your Chrome extensions. |

Only located Safari/Chrome installations are offered. A real-browser card needs
an HTTP(S) starting address. The first explicit selection opens that address;
subsequent selections switch to the running browser app without opening another
copy of the address. **Open Website** deliberately opens the saved address again.
If the browser has closed, selecting its card reopens it. Restoring Lantern's
cards at startup does not automatically launch or focus an external browser.

The external panel shows the browser name/icon, address and status, with
**Open / Switch**, **Open Website**, and **Change URL…**. Switching activates
the app; it cannot guarantee a particular window, tab or profile. Choose the
profile in Safari/Chrome itself. Removing a card does not close the browser.
Existing cards keep their browser type; add a different card to change type.
These cards do not take browser screenshots, read profile files, or request
screen-recording, Accessibility or browser-automation permissions.

For **Lantern · inside this window**, the starting address and name are optional;
a blank address starts a new tab, and an unnamed window gets a name such as
**Browser 1**. Each internal window has its own tab strip: **+ / Command–T** adds
a tab, its close button or **Command–W** closes it, and the last close leaves a
fresh new tab. Popup links stay in that same internal window. Existing
single-address cards migrate to one-tab Lantern windows with their aliases
preserved.

Back, Forward and **Command–L / R / [ / ]** act on the selected internal tab.
The toolbar's Reload control becomes **Stop** while that tab is loading; Stop
cancels its pending load and preserves the requested address for another try.
Afterward it returns to Reload. **Command–R** always reloads. Use
**Command–Shift–[ / ]** or **Control–Tab / Control–Shift–Tab** to switch tabs.
These shortcuts apply to the selected internal browser, not a VNC computer.

Internal windows keep up to 12 tabs each. Up to 100 browser cards can be recorded;
at most six internal WebKit windows stay loaded. Their inactive least recently
used windows sleep and restore saved tab URLs/selection on demand, so unsaved
forms and page state may be lost. Tabs load lazily. Internal background previews
refresh about every ten seconds; repeated sampling pauses for the selected
screen while its main view runs normally. External-browser cards use an icon
and app status instead of a captured desktop preview.

The internal WebKit browser does not promise full-browser compatibility:
downloads are unsupported and reported inline, HTTP authentication/credential
authorization dialogs are disabled, and some OAuth or extension-dependent
workflows need real Safari/Chrome. Sites may also present their own verification
pages. See the [browser FAQ](docs/wiki/FAQ.md#can-i-open-websites-in-lantern) and
[verification troubleshooting](docs/wiki/Troubleshooting.md#a-website-shows-verification-or-keeps-loading).

## Optional support and feedback

Choose the route that fits your message:

- [Report a bug](https://github.com/py-killer/lantern-vnc/issues/new?template=bug_report.yml), even if you cannot reproduce it yet.
- [Suggest an idea](https://github.com/py-killer/lantern-vnc/issues/new?template=feature_request.yml) or [ask a question](https://github.com/py-killer/lantern-vnc/issues/new?template=question.yml).
- [Share thanks or a working setup](https://github.com/py-killer/lantern-vnc/issues/new?template=thanks.yml).
- [Use website feedback without GitHub sign-in](https://py-killer.github.io/lantern-vnc/#feedback).

The app's **Help → Send Feedback…** opens the website feedback form in your
browser. GitHub issue forms are another option and may require a GitHub
sign-in; that account is never required to run Lantern VNC. The website form sends feedback only when you submit it
and shows a receipt after a successful submission. Read its privacy notice
before sending. A failed or offline submission has not reached maintainers.
Neither route is required to use the app, and neither promises an instant
reply. Leave passwords, private server details, and personal desktop data
out of reports. See [the community guide](COMMUNITY.md) for how reports are
handled and [the security policy](SECURITY.md) for possible vulnerabilities.

Use **Help → Save Feedback…** to write a local text file containing your notes,
app version, release channel/build, macOS version, GPU name, and renderer name. The app does not
automatically add a server address, password, clipboard contents, or network
credentials. Review your own notes before sharing the file. Saving feedback
does not send it anywhere.

The support command opens the website's
[support section](https://py-killer.github.io/lantern-vnc/#support). Tipping is
not enabled: the optional interest poll only asks whether you find Lantern
useful and would consider donating. Clicking it records your answer and
shows thanks; it makes no payment or pledge. Every feature remains free.

## Privacy and network security

Lantern VNC connects directly to your connected VNC servers. It has no account
service, analytics, cloud relay, or licensing server. Saved server settings
stay in the app's local preferences. VNC passwords stay in process memory
for connection setup unless you explicitly enable **Remember password**.
Remembered passwords use the classic macOS login Keychain with Keychain
synchronization disabled; plaintext passwords are never written to
preferences or device profiles, or automatically included in feedback exports. This is not a claim that
Keychain items are excluded from every backup. Keychain errors leave manual
password entry available. **Find…** makes bounded, user-requested local
connections solely to check VNC greetings. Enabling
clipboard sharing transfers clipboard text between your Mac and the server;
leave it disabled if you do not want that transfer.

Saved computers with an accessible remembered password can reconnect for
background previews when the app opens. Those connections are read-only until
selected. Computer and internal-browser thumbnails stay in RAM only. Browser addresses,
names and selected browser types are saved locally. The internal browser uses
Lantern's own persistent WebKit cookies/storage; external Safari/Chrome cards
leave sessions and extensions in those actual apps and do not read their profiles. Pages make normal requests to the sites you open,
which have their own privacy policies and may collect data. Lantern does not
import Safari/Chrome data or turn browser activity into app analytics.

The project website is separate from the desktop app. Its explicit feedback
form sends the selected feedback kind, message, and random visitor/event
identifiers to the website service. Its privacy notice explains those fields
and optional aggregate website counts, including how to stop automatic
counts. Website collection does not add analytics to the app, and visiting
the website or submitting feedback is not required for a VNC connection.

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
- **Find… returns no results:** check local-network permission, Wi-Fi/Ethernet,
  and the selected port, then retry. Discovery does not search VPNs, IPv6, or
  every port; enter a known server address manually when needed.
- **Authentication failed:** check the TightVNC VNC password and whether the
  server offers standard VNC password authentication. This build does not
  provide RealVNC cloud login or enterprise identity authentication. A wrong
  password does not establish that the server address or port is wrong.
- **Connected but input does nothing:** turn off Hand, disable View only, and confirm the
  server account/password grants control. A view-only TightVNC password
  remains view-only even when the app's checkbox is off.
- **Desktop edges are out of view:** use the visible scroll bars or Hand. Use
  Fit to Window for an overview, or a larger explicit zoom for readable text.
- **Screen looks stale:** request a full update with Refresh screen.
- **Updates feel slow:** compare Wi-Fi and Balanced after reconnecting if the
  server may be CPU-limited. Fit changes the local view, not the amount of
  remote desktop requested. Local copy improvements cannot fix a blocked or
  unreliable network path.
- **RTT is low but the screen lags:** RTT measures the TCP connection, not
  capture, encoding, or display completion. Check the server workload and
  picture preset; a local port-forward endpoint can also have low RTT while
  the remote route remains slow.

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
open "build/artifacts.noindex/Lantern VNC.app"
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
./tests/run-workspace-tests.sh
./tests/run-browser-tests.sh
./tests/run-browser-store-tests.sh
./tests/run-external-browser-tests.sh
EXTERNAL_BROWSER_PANEL_TESTS=1 ./tests/run-external-browser-tests.sh
./tests/run-external-workspace-tests.sh
./tests/run-screen-preview-tests.sh
SCREEN_PREVIEW_SANITIZE=1 ./tests/run-screen-preview-tests.sh
./tests/run-screen-cards-tests.sh
./tests/run-network-discovery-tests.sh
./tests/run-password-tests.sh
./tests/run-frame-update-tests.sh
FRAME_TEST_SANITIZE=1 ./tests/run-frame-update-tests.sh
```

The protocol tests cover raw/Tight/JPEG decoded pixels, compression and JPEG
negotiation, remote resizing, input/clipboard messages, view-only suppression,
authentication failures, cancellation, connection errors, and repeated cleanup.
The display test script checks
viewport geometry and an owned offscreen native window with synthetic
frames and events. It does not send input to a real remote desktop. If Metal
or WindowServer is unavailable, that native harness reports exit 77 rather
than a passing result.

Workspace tests combine two owned loopback VNC servers and local HTTP pages
inside an offscreen controller. They check retained session identity, input
isolation, background thumbnails, browser switching/navigation, and removal.
They use isolated preferences, fake credentials, and an ephemeral browser data
store. Browser component tests cover their local controls and failure states;
they do not establish compatibility with every public website or OAuth flow.

The frame-update tests reconstruct pixels against an independent oracle
through dirty updates, coalescing, resizing, stale display buffers, and
concurrent receives. Their 5K copy benchmark reports CPU timing and byte
counts separately from GPU or network performance. Mock protocol tests also
check queued input during fragmented screen and capability messages.

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
directory can be passed as its first argument. It verifies signatures and
bundles the license notices. Published previews use the project's self-signed
publisher certificate and preserve the credential helper byte for byte when
resealing the main app. Apple Developer ID signing and notarization remain
pending; macOS may require approval to open a trusted copy.

Ordinary development builds use ad hoc signatures without the publisher's
private signing material. Their persistent credential helper is unavailable;
manual VNC connections still work. To create an independent helper with your
own identity, read the [credential-service build guide](native/credential-vault/README.md).
Private signing keys and password files are never included in the source archive.

## Community

Start with [community and feedback](COMMUNITY.md) or the
[web wiki](https://py-killer.github.io/lantern-vnc/wiki/). Maintainers and
configured maintenance automation may investigate real reports, fix issues,
and reply directly in GitHub. Maintenance is best effort, without a promised
response time. See [Contributing](CONTRIBUTING.md), the
[code of conduct](CODE_OF_CONDUCT.md), and the [security policy](SECURITY.md).
Issues and pull requests are public; review notes and screenshots before
sharing. [Unpublished promotion drafts](docs/PROMOTION.md) document current
claims and posting venues; they are not external posts.

## License and acknowledgments

Lantern VNC's application code, wrapper, scripts, and original icon artwork
are provided under GNU GPL version 2 or, at your option, any later version.
See `LICENSE` and `THIRD_PARTY_NOTICES.md`. There is no warranty. Keep the
matching source archive and licenses available when redistributing the app.
The free current version does not depend on donations or a subscription.

This software is based in part on the work of the Independent JPEG Group.
