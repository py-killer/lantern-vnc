# Third-party notices

Lantern VNC uses the following components. The project-specific application
code, bridge, icon artwork, and scripts are licensed under GNU GPL version 2
or, at your option, any later version. The full GPL version 2 text is in
`LICENSE`. Upstream files retain their own copyright and license notices.

## LibVNCClient / LibVNCServer 0.9.15

Project: https://github.com/LibVNC/libvncserver

Lantern VNC statically links LibVNCClient, built from the LibVNCServer source
release 0.9.15. LibVNCClient is licensed under GNU GPL version 2 or, at your
option, any later version. The upstream source includes copyright notices for
AT&T Laboratories Cambridge, Tridia Corporation, Const Kaplinsky, D. R.
Commander, Christian Beier, and other contributors; the original notices are
preserved in `vendor/libvncserver`.

Full license: `licenses/LibVNCClient-GPL-2.0.txt` and
`vendor/libvncserver/COPYING`. Corresponding source is provided in the source
archive, including the build scripts used for the application.

The bundled source includes small Lantern VNC modifications, marked in
`include/rfb/rfbclient.h`, `src/libvncclient/sockets.c`, and
`src/libvncclient/rfbclient.c`. An optional read-wake hook lets the existing
connection thread service outgoing input while waiting for a fragmented
server message; it does not re-enter the RFB parser. Capability messages are
read into temporary storage before publishing their complete flags. The
hook defaults to disabled and does not change the `rfbClient` structure
layout. These modifications remain GPL-2.0-or-later and are included in the
corresponding vendor source and build scripts supplied with Lantern VNC.

## libjpeg-turbo 3.2.1 and the Independent JPEG Group

Project: https://github.com/libjpeg-turbo/libjpeg-turbo

Lantern VNC statically links the libjpeg API library from libjpeg-turbo 3.2.1
for Tight JPEG decoding, including its Apple Silicon SIMD implementation.
The libjpeg API library is covered by the IJG License; the distribution also
contains BSD-style and zlib-licensed components. Original copyright notices
and the complete upstream license documentation are preserved in
`vendor/libjpeg-turbo`.

**This software is based in part on the work of the Independent JPEG Group.**

Full notices and terms: `licenses/libjpeg-turbo-LICENSE.md` and
`licenses/libjpeg-turbo-README.ijg`, also present in the vendor source tree.
Neither the Independent JPEG Group nor the libjpeg-turbo project endorses
Lantern VNC.

## zlib supplied by macOS

Project: https://zlib.net/

The application dynamically links the operating system's zlib for compression
and decompression. zlib is copyright Jean-loup Gailly and Mark Adler and is
provided under the zlib License. The notice supplied by the build SDK is
reproduced in `licenses/zlib-LICENSE.txt`. The system library itself is
supplied with macOS and is not included in this distribution.

## Apple system frameworks and runtime

The application uses AppKit, Metal, MetalKit, QuartzCore, Foundation, and the
Swift runtime supplied by Apple on macOS. These operating system components
are not included in the source archive. Apple, macOS, Mac, AppKit, Metal, and
Swift are trademarks of Apple Inc. Lantern VNC is an independent project.

## Distribution

Keep these notices and the included license texts with redistributed copies.
When distributing the GPL-covered executable, provide its corresponding
source under the GPL, including the application, wrapper, vendor sources,
and build scripts. The `Lantern-VNC-source.zip` archive supplied alongside the
application contains this source. No warranty is provided; see `LICENSE` and
the component licenses for the governing terms.
