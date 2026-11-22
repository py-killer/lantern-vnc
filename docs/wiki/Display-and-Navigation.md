# Display and navigation

[Wiki home](Home.md) · [Getting started](Getting-Started.md) · [Troubleshooting](Troubleshooting.md)

This guide describes the implemented **1.2.0-preview.2**. It remains a preview: physical external-display transitions and the complete manual hardware matrix have not been verified.

The server supplies its desktop resolution. Lantern's zoom, window size, and local navigation change your view of that image; they never change the server's display resolution.

## Select a screen

Choose a named card in the sidebar. Connected VNC computers retain their sessions when another card is selected. Background sessions are read-only and request updates at roughly ten-second intervals; the selected computer resumes foreground updates and alone receives remote input. Switching to a local browser sends no input to the VNC computers. Switching does not replace the existing Metal viewport or change the server's resolution.

Computer and internal WebKit thumbnails are small, aspect-correct samples kept in RAM only. Background preview requests/samples are normally paced about every ten seconds. The selected screen receives an initial thumbnail, then repeated sampling pauses while its full desktop or internal browser page continues at normal foreground speed. A card's age is the time since its last sample; a disconnected card may show a labeled last capture. External Safari/Chrome cards use the app icon and status without screenshot capture. Do not use thumbnails or their ages as a latency measurement or proof of connectivity.

Live and connecting cards keep their saved order, and selecting a card does not move it. Offline, sleeping or closing screens move to the bottom; on becoming live again, they return to their original position among live cards. Each **Lantern · inside this window** card contains its own tab strip, so switching its tabs leaves the sidebar selection unchanged. Use **+ / Command–T** to add a tab and its close button or **Command–W** to close one; closing the last page leaves a fresh new tab.

In the selected internal browser window, **Command–Shift–[ / ]** chooses the previous/next tab and **Control–Tab / Control–Shift–Tab** the next/previous tab. **Command–L / R / [ / ]** focuses the address, reloads, or navigates Back/Forward within its selected tab. Its Reload button becomes **Stop** while loading; Stop cancels only that tab's pending load and keeps the requested address for retry. Afterward the button returns to Reload. Command–R always reloads. Browser shortcuts do not send input to a VNC computer.

Selecting an installed Safari/Chrome card opens its saved HTTP(S) address the first time, then switches to the running browser app on later selections. **Open Website** opens that address again deliberately; **Change URL…** edits the saved target. Restoring cards on launch does not automatically open an external browser, and removing a card does not close it. App switching cannot guarantee a particular browser window, tab or profile. These external windows use their own native controls and extensions, not Lantern's WebKit toolbar.

Context-click computer cards to rename, disconnect, or remove them, and browser cards to edit or remove them. **Connection settings** reveals the selected VNC endpoint's fields. Browser toolbar shortcuts apply locally to WebKit; VNC zoom/input controls apply to the selected remote desktop. See [Getting started](Getting-Started.md#add-a-local-website) for browser limits.

## Choose a viewing mode

| Mode | What it does | When to use it |
| --- | --- | --- |
| **Fit to Window** | Default for a new host/port. Fits the complete image inside the viewport with its aspect ratio preserved. Different image/window shapes produce letterboxing. | Get a whole-desktop overview; text can become small at high remote resolutions. |
| **Auto (Readable)** | Uses `max(100%, min(Fit zoom, 200%))` in drawable/backing pixels. A large desktop stays at 100% rather than shrinking to fit. | Choose readable detail and navigate when the image exceeds the viewport. |
| **50%, 75%, 100%, 125%, 150%, 200%** | Selects an explicit local scale. At 100%, one remote pixel maps to one Metal drawable/backing pixel. | Choose a predictable size; use a larger percentage for bigger text. |
| **Custom pinch zoom** | A trackpad pinch selects a custom scale between 10% and 400%. | Adjust around the point you are inspecting. |

For example, a new 5120 × 2880 desktop starts fitted so every edge is visible. If the text is too small, choose Auto to view it at 100% or more and navigate with scroll bars or Hand. Explicit higher zoom also makes text larger.

Lantern saves your selected mode, including custom pinch scale, separately for each host and TCP port and restores it after reconnecting or restarting the app. Pan positions are not remembered. Changing the endpoint restores that endpoint's settings, or Fit for a new one.

On a Retina screen, Mac points and drawable/backing pixels are different units. At 100%, remote text can therefore look smaller than Mac interface text. macOS scaled display modes may also resample the final panel image. Use a higher explicit zoom when needed; Auto avoids downscaling but does not promise identical text sizes across machines.

## Reach an oversized desktop's edges

Native horizontal and vertical scroll bars stay visible on the axes where the scaled image exceeds the viewport. Drag their thumbs to move around the desktop. If the whole image fits, that axis does not need a scroll bar.

Turn on **Hand** for local navigation:

- Drag the image to move your local view.
- Use the wheel/trackpad to pan locally.
- Use arrow keys to pan.
- Press **Escape** or turn Hand off to return to remote control.

Hand is enabled when the connected desktop can be panned. While Hand is active, the viewer treats these actions locally and suppresses remote pointer, wheel, and keyboard input. With Hand off, click the image to focus it and use normal scrolling to control the remote app. This distinction prevents local panning from accidentally scrolling or dragging something on the other computer.

## Make more room and change zoom quickly

| Action | Shortcut |
| --- | --- |
| Show/hide the connection sidebar | **Control–Command–S** or **Hide settings / Show settings** beside the zoom menu |
| Zoom in / out | **Control–Command–+ / −** |
| Actual size, 100% | **Control–Command–0** |
| Toggle full screen | **Control–Command–F** |
| Connect / disconnect | **Command–K** |

Entering full screen hides the connection sidebar; leaving full screen restores its previous state. The zoom popup and View menu provide the viewing controls without shortcuts.

Lantern also remembers the last normal window size and position across app launches. On reopening, it recovers offscreen placement onto an available screen if the previous monitor is missing. These local window settings keep the server's resolution unchanged. Your Fit/zoom and picture preset remain saved separately for each host and port. Physical monitor transitions still need the manual checks listed below.

## How the viewport works

Metal renders a viewport the size of the visible local area. A separate pan offset selects which part of the remote image is visible. Rendering and remote pointer coordinates use the same geometry transform, so the image and click mapping follow the same zoom and pan state. The Metal drawable does not grow to the full dimensions of an oversized desktop.

Preview 5 copies changed parts of the decoded image and uploads those regions to the GPU. Each display buffer accumulates the changes it still needs, so skipped draws do not leave stale areas. Full-screen updates still require full-image work. This preserves the decoded pixels, chosen picture preset, and server resolution; it does not change VNC network compression. Queued input can also be sent while a partial screen message waits for more data. Neither change guarantees a Wi-Fi or end-to-end speed increase.

Click positions still need validation after a display change. If clicks land incorrectly, report the zoom mode, pan position, window size, and whether the issue followed a resize, reconnect, remote resolution change, or move between displays.

## Read network RTT

While connected, **RTT** is displayed below the connection status and refreshed once per second. It reads macOS's smoothed TCP round-trip estimate for that connection, in milliseconds. It does not measure input-to-screen delay. The units and smoothed field are defined in [Apple's TCP header](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/netinet/tcp.h); the [XNU export implementation](https://raw.githubusercontent.com/apple-oss-distributions/xnu/main/bsd/netinet/tcp_usrreq.c) returns the kernel estimate.

**RTT unavailable** means there is no usable estimate, including an unavailable or zero value. After five seconds without an observed transport-counter change, the line adds **idle**. The tooltip may show when a traffic-counter change was last observed; this is not the age of the RTT sample. Polling once a second does not create a fresh RTT measurement, and an idle connection can retain an older estimate.

The TCP peer can be a local forwarding endpoint. For example, an SSH port forward on your Mac can have a low local RTT while its onward route to the remote computer is slow. Even on a direct connection, capture, encoding, transfer, decoding, and rendering can add delay beyond this number.

The indicator sends no extra probes, synthetic input, or screen-update requests and adds no analytics. It changes neither picture presets nor decoded pixels, rendering, or server resolution.

## Picture quality and input are separate controls

Choose a picture preset before connecting. It is saved for that host and port, including across app restarts, and applies on the next connection. Existing devices inherit the former global picture preset once during upgrade; later changes remain independent.

| Preset | Tight JPEG request | Compression request |
| --- | --- | --- |
| **Wi-Fi · high quality** | Level 8, the same as Balanced | 3; default for a new endpoint |
| **Balanced · fast LAN** | Level 8 | 1 |
| **Lossless · sharp text** | Disabled | 1; transfer remains compressed |
| **Fast · lower bandwidth** | Level 5 | 1 |

Wi-Fi requests moderate extra compression that may reduce transferred bytes while using more server CPU. It does not guarantee the fastest result. These are fixed requests to the server, with no automatic adaptation. Compression levels apply to Tight/Zlib; the server may choose another supported encoding.

JPEG levels are coarse protocol values from 0–9, not percentages. JPEG-enabled presets can affect text, especially in image-rich regions. Lossless requests exact decoded pixels by disabling JPEG; fractional local zoom or macOS display scaling may still soften their appearance. Picture presets change neither the server resolution nor the local zoom.

**View only** suppresses keyboard, pointer, and clipboard changes sent to the server. Local navigation remains useful for inspecting a view-only session. Optional **Map Command to Control** helps with Windows/Linux shortcuts, and **Ctrl–Alt–Del** is an explicit toolbar action.

## Preview verification limits

The controls above are implemented in the local preview candidate. Automated geometry/protocol checks and a synthetic native GPU harness cover different parts of the behavior; they do not prove every physical-display configuration. Physical 1× external/2× Retina switching, monitor disconnect/reconnect, macOS scaled modes, and the full manual resolution/window matrix remain unverified.

See the [release checklist](../RELEASE_CHECKLIST.md). Unchecked cases are not passes. For a useful report, include app version, remote width × height, local window/viewport size, display/backing scale, mode/percentage, reachable corners, and whether known test targets receive correct clicks. Use synthetic screenshots rather than personal desktop content.
