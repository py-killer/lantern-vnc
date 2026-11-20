# Display and navigation

[Wiki home](Home.md) · [Getting started](Getting-Started.md) · [Troubleshooting](Troubleshooting.md)

This guide describes the implemented **1.1.0-preview.1 candidate**. It replaces the 1.0 navigation model. It remains a preview: physical external-display transitions and the complete manual hardware matrix have not been verified.

The server supplies its desktop resolution. Lantern's zoom, window size, and local navigation change your view of that image; they never change the server's display resolution.

## Choose a viewing mode

| Mode | What it does | When to use it |
| --- | --- | --- |
| **Auto (Readable)** | Uses `max(100%, min(Fit zoom, 200%))` in drawable/backing pixels. A large desktop stays at 100% rather than shrinking to fit. | Start here for readable detail and navigate when the image exceeds the viewport. |
| **Fit to Window** | Fits the complete image inside the viewport with its aspect ratio preserved. Different image/window shapes produce letterboxing. | Get a whole-desktop overview; text can become small at high remote resolutions. |
| **50%, 75%, 100%, 125%, 150%, 200%** | Selects an explicit local scale. At 100%, one remote pixel maps to one Metal drawable/backing pixel. | Choose a predictable size; use a larger percentage for bigger text. |
| **Custom pinch zoom** | A trackpad pinch selects a custom scale between 10% and 400%. | Adjust around the point you are inspecting. |

For example, a 5120 × 2880 desktop on a much smaller viewport starts at 100% in Auto and remains navigable. It is not forced into a tiny whole-image view. Fit to Window is the explicit choice when you want every edge visible at once.

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
| Show/hide the connection sidebar | **Control–Command–S** or the sidebar button |
| Zoom in / out | **Control–Command–+ / −** |
| Actual size, 100% | **Control–Command–0** |
| Toggle full screen | **Control–Command–F** |
| Connect / disconnect | **Command–K** |

Entering full screen hides the connection sidebar; leaving full screen restores its previous state. The zoom popup and View menu provide the viewing controls without shortcuts.

## How the viewport works

Metal renders a viewport the size of the visible local area. A separate pan offset selects which part of the remote image is visible. Rendering and remote pointer coordinates use the same geometry transform, so the image and click mapping follow the same zoom and pan state. The Metal drawable does not grow to the full dimensions of an oversized desktop.

Click positions still need validation after a display change. If clicks land incorrectly, report the zoom mode, pan position, window size, and whether the issue followed a resize, reconnect, remote resolution change, or move between displays.

## Picture quality and input are separate controls

**Balanced**, **Lossless**, and **Fast** select picture quality before connecting. They do not change the server resolution or local zoom. Lossless avoids JPEG compression; it does not make text larger.

**View only** suppresses keyboard, pointer, and clipboard changes sent to the server. Local navigation remains useful for inspecting a view-only session. Optional **Map Command to Control** helps with Windows/Linux shortcuts, and **Ctrl–Alt–Del** is an explicit toolbar action.

## Preview verification limits

The controls above are implemented in the local preview candidate. Automated geometry/protocol checks and a synthetic native GPU harness cover different parts of the behavior; they do not prove every physical-display configuration. Physical 1× external/2× Retina switching, monitor disconnect/reconnect, macOS scaled modes, and the full manual resolution/window matrix remain unverified.

See the [release checklist](../RELEASE_CHECKLIST.md). Unchecked cases are not passes. For a useful report, include app version, remote width × height, local window/viewport size, display/backing scale, mode/percentage, reachable corners, and whether known test targets receive correct clicks. Use synthetic screenshots rather than personal desktop content.
