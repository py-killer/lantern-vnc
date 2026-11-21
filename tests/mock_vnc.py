#!/usr/bin/env python3
"""Small local RFB 3.8 server for integration tests and visual QA. No real hosts."""
import argparse
import base64
import ctypes
import json
from pathlib import Path
import socket
import socketserver
import struct
import threading
import time
import zlib


# Created offline with libjpeg-turbo: 4x3 RGB, quality 95, 4:4:4 sampling.
# Each row is red/green/blue/white; JPEG decoding permits a small tolerance.
# Runtime needs only the Python standard library, never Pillow or an encoder.
JPEG_FIXTURE = base64.b64decode(
    "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAIBAQEBAQIBAQECAgICAgQDAgICAgUEBAMEBgUG"
    "BgYFBgYGBwkIBgcJBwYGCAsICQoKCgoKBggLDAsKDAkKCgr/2wBDAQICAgICAgUDAwUKBwYH"
    "CgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgr/wAAR"
    "CAADAAQDAREAAhEBAxEB/8QAFAABAAAAAAAAAAAAAAAAAAAACP/EABsQAAAHAQAAAAAAAAAA"
    "AAAAAAAEBgcKOHe2/8QAFQEBAQAAAAAAAAAAAAAAAAAAAAH/xAAcEQABBAMBAAAAAAAAAAAA"
    "AAAFAAQGtTY3dHX/2gAMAwEAAhEDEQA/AH7Haqs4WmEeMTAAtVRbmeXJRQjnkq9oxZOV/9k="
)


def read_exact(sock, length):
    data = bytearray()
    while len(data) < length:
        part = sock.recv(length - len(data))
        if not part:
            raise EOFError()
        data.extend(part)
    return bytes(data)


def rect(x, y, width, height, encoding, payload=b""):
    return struct.pack("!HHHHi", x, y, width, height, encoding) + payload


def update(*rectangles):
    return struct.pack("!BBH", 0, 0, len(rectangles)) + b"".join(rectangles)


def pixel(r, g, b):
    return bytes((b, g, r, 0))


def pixels(width, height, color):
    return pixel(*color) * (width * height)


def vnc_response(challenge, password):
    """Independent DES implementation supplied by macOS CommonCrypto."""
    common_crypto = ctypes.CDLL('/usr/lib/system/libcommonCrypto.dylib')
    crypt = common_crypto.CCCrypt
    crypt.argtypes = (ctypes.c_uint, ctypes.c_uint, ctypes.c_uint,
                      ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p,
                      ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p,
                      ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t))
    crypt.restype = ctypes.c_int
    raw_key = password.encode('latin1')[:8].ljust(8, b'\0')
    reversed_key = bytes(int('{:08b}'.format(byte)[::-1], 2) for byte in raw_key)
    key = ctypes.create_string_buffer(reversed_key)
    source = ctypes.create_string_buffer(challenge)
    output = ctypes.create_string_buffer(16)
    moved = ctypes.c_size_t()
    # kCCEncrypt=0, kCCAlgorithmDES=1, kCCOptionECBMode=2. No padding.
    result = crypt(0, 1, 2, key, 8, None, source, 16, output, 16, ctypes.byref(moved))
    if result or moved.value != 16:
        raise RuntimeError('CommonCrypto DES failed: %s' % result)
    return output.raw


def tight_length(length):
    compact = bytearray()
    for _ in range(2):
        if length < 128:
            compact.append(length)
            break
        compact.append((length & 127) | 128)
        length >>= 7
    else:
        compact.append(length)
    return bytes(compact)


def tight_basic(image):
    rgb = bytearray()
    for index in range(0, len(image), 4):
        rgb.extend((image[index + 2], image[index + 1], image[index]))
    encoder = zlib.compressobj()
    compressed = encoder.compress(bytes(rgb)) + encoder.flush(zlib.Z_SYNC_FLUSH)
    # Reset zlib stream0, basic compression, no palette/gradient filter.
    return b'\x01' + tight_length(len(compressed)) + compressed


def tight_jpeg():
    # Tight's JPEG subencoding is 0x9 in the control byte's high nibble.
    return b'\x90' + tight_length(len(JPEG_FIXTURE)) + JPEG_FIXTURE


# Public-domain 5x7 pixel alphabet used only by the test server.
FONT = {
    "A": [14,17,17,31,17,17,17], "B": [30,17,17,30,17,17,30],
    "C": [14,17,16,16,16,17,14], "D": [30,17,17,17,17,17,30],
    "E": [31,16,16,30,16,16,31], "F": [31,16,16,30,16,16,16],
    "G": [14,17,16,23,17,17,15], "H": [17,17,17,31,17,17,17],
    "I": [31,4,4,4,4,4,31], "J": [7,2,2,2,18,18,12],
    "K": [17,18,20,24,20,18,17], "L": [16,16,16,16,16,16,31],
    "M": [17,27,21,21,17,17,17], "N": [17,25,21,19,17,17,17],
    "O": [14,17,17,17,17,17,14], "P": [30,17,17,30,16,16,16],
    "Q": [14,17,17,17,21,18,13], "R": [30,17,17,30,20,18,17],
    "S": [15,16,16,14,1,1,30], "T": [31,4,4,4,4,4,4],
    "U": [17,17,17,17,17,17,14], "V": [17,17,17,17,17,10,4],
    "W": [17,17,17,21,21,21,10], "X": [17,17,10,4,10,17,17],
    "Y": [17,17,10,4,4,4,4], "Z": [31,1,2,4,8,16,31],
    "0": [14,17,19,21,25,17,14], "1": [4,12,4,4,4,4,14],
    "2": [14,17,1,2,4,8,31], "3": [30,1,1,14,1,1,30],
    "4": [2,6,10,18,31,2,2], "5": [31,16,16,30,1,1,30],
    "6": [14,16,16,30,17,17,14], "7": [31,1,2,4,8,8,8],
    "8": [14,17,17,14,17,17,14], "9": [14,17,17,15,1,1,14],
    ".": [0,0,0,0,0,6,6], ":": [0,6,6,0,6,6,0],
    "-": [0,0,0,31,0,0,0], "/": [1,2,2,4,8,8,16],
}


def desktop():
    width, height = 960, 600
    image = bytearray(pixels(width, height, (16, 23, 34)))

    def box(x, y, w, h, color):
        row = pixel(*color) * w
        for yy in range(y, y + h):
            start = (yy * width + x) * 4
            image[start:start + w * 4] = row

    def text(x, y, value, color=(226, 235, 245), scale=3):
        for char in value.upper():
            for yy, bits in enumerate(FONT.get(char, [0] * 7)):
                for xx in range(5):
                    if bits & (1 << (4 - xx)):
                        box(x + xx * scale, y + yy * scale, scale, scale, color)
            x += 6 * scale

    box(0, 0, width, 48, (29, 40, 56))
    text(25, 15, "LOCAL TEST DESKTOP", scale=2)
    text(50, 95, "NATIVE VNC", scale=6)
    text(52, 165, "APPLE SILICON / RFB 3.8", (119, 153, 180), 2)
    colors = [(35, 191, 156), (77, 143, 248), (227, 162, 62)]
    for index, color in enumerate(colors):
        box(50 + 290 * index, 235, 270, 180, color)
        text(70 + 290 * index, 270, ["BGRX", "POINTER", "KEYBOARD"][index], (9, 29, 42), 3)
        text(70 + 290 * index, 355, ["COLOR OK", "CLICK ME", "TYPE HERE"][index], (9, 29, 42), 2)
    text(52, 465, "THIS IS A LOCAL MOCK SERVER", scale=3)
    text(52, 515, "YOUR TIGHTVNC HOST WAS NOT CONTACTED", (119, 153, 180), 2)
    return width, height, bytes(image)


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, address, args):
        super().__init__(address, Handler)
        self.args = args
        self.log_lock = threading.Lock()
        self.counter = 0

    def log(self, connection, event, **values):
        if not self.args.events:
            return
        with self.log_lock:
            with open(self.args.events, "a", encoding="utf8") as output:
                output.write(json.dumps({"connection": connection, "event": event, **values}) + "\n")


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        with self.server.log_lock:
            self.server.counter += 1
            connection = self.server.counter
        self.connection_id = connection
        try:
            self.session()
        except (EOFError, OSError, ValueError, struct.error):
            pass
        finally:
            self.server.log(connection, "closed")

    def session(self):
        sock = self.request
        sock.settimeout(10)
        mode = self.server.args.scenario
        if mode == "stall":
            while sock.recv(1024):
                pass
            return
        sock.sendall(b"RFB 003.008\n")
        read_exact(sock, 12)
        auth = mode in ("auth-fail", "password")
        sock.sendall(bytes((1, 2 if auth else 1)))
        read_exact(sock, 1)
        if auth:
            challenge = bytes(range(16))
            sock.sendall(challenge)
            response = read_exact(sock, 16)
            self.server.log(self.connection_id, "auth-response", length=len(response))
            if mode == "auth-fail" or response != vnc_response(challenge, 'mock-password'):
                reason = b"Mock authentication rejected"
                sock.sendall(struct.pack("!II", 1, len(reason)) + reason)
                return
            self.server.log(self.connection_id, "password-verified")
        sock.sendall(struct.pack("!I", 0))
        read_exact(sock, 1)
        if mode == "interactive":
            width, height, image = desktop()
        elif mode.startswith("slow-"):
            width, height = (4096, 2) if mode == "slow-large" else (4, 3)
            image = pixels(width, height, (25, 50, 75))
        else:
            width, height = 4, 3
            image = (pixel(255, 0, 0) + pixel(0, 255, 0) + pixel(0, 0, 255) + pixel(255, 255, 255)) * 3
        name = b"Native VNC local integration desktop"
        pixel_format = struct.pack("!BBBBHHHBBB3x", 32, 24, 0, 1, 255, 255, 255, 16, 8, 0)
        sock.sendall(struct.pack("!HH", width, height) + pixel_format + struct.pack("!I", len(name)) + name)
        stage = 0
        slow_pending = threading.Event()
        while True:
            message = read_exact(sock, 1)[0]
            if message == 0:
                read_exact(sock, 3)
                fmt = read_exact(sock, 16)
                self.server.log(self.connection_id, "pixel-format", format=list(fmt))
            elif message == 2:
                _, count = struct.unpack("!BH", read_exact(sock, 3))
                encodings = struct.unpack("!" + "i" * count, read_exact(sock, count * 4))
                self.server.log(self.connection_id, "encodings", values=encodings)
            elif message == 3:
                read_exact(sock, 9)
                if mode == "rtt-idle":
                    self.server.log(self.connection_id, "update-request")
                if mode == "oversize":
                    sock.sendall(update(rect(0, 0, 65535, 65535, -223)))
                    mode = "sent-oversize"
                elif stage == 0:
                    if mode == 'tight':
                        sock.sendall(update(rect(0, 0, width, height, 7, tight_basic(image))))
                    elif mode == 'jpeg':
                        sock.sendall(update(rect(0, 0, width, height, 7, tight_jpeg())))
                        self.server.log(self.connection_id, "jpeg-sent", length=len(JPEG_FIXTURE), width=width, height=height)
                    else:
                        sock.sendall(update(rect(0, 0, width, height, 0, image)))
                    clipboard = b"Remote clipboard caf\xe9"
                    sock.sendall(struct.pack("!B3xI", 3, len(clipboard)) + clipboard)
                    stage += 1
                    if mode == "drop":
                        return
                elif mode.startswith("slow-") and stage == 1:
                    image = pixels(width, height, (80, 90, 100))
                    if mode == "slow-capabilities":
                        # The first capability byte clears support for input.
                        # It must not take effect until all 64 bytes arrive.
                        # Include a normal rectangle after it for frame parity.
                        capabilities = b'\0' + b'\xff' * 63
                        packet = update(rect(0, 0, 64, 0, -131071, capabilities),
                                        rect(0, 0, width, height, 0, image))
                    else:
                        packet = update(rect(0, 0, width, height, 0, image))
                    # The server's reader keeps accepting input while another
                    # thread withholds the rest of this framebuffer payload.
                    # 4x3 exercises LibVNCClient's buffered read branch; 4096x2
                    # requires its direct large-payload branch (>8192 bytes).
                    slow_pending.set()
                    sock.sendall(packet[:20])
                    self.server.log(self.connection_id, "slow-update-started", at=time.monotonic())
                    def finish_slow(packet=packet, drop=mode == "slow-drop"):
                        time.sleep(0.9)
                        slow_pending.clear()
                        self.server.log(self.connection_id, "slow-update-release", at=time.monotonic())
                        try:
                            if drop:
                                sock.shutdown(socket.SHUT_RDWR)
                            else:
                                sock.sendall(packet[20:])
                                self.server.log(self.connection_id, "slow-update-complete", at=time.monotonic())
                        except OSError:
                            self.server.log(self.connection_id, "slow-update-aborted")
                    threading.Thread(target=finish_slow, daemon=True).start()
                    stage += 1
                elif mode.startswith("slow-"):
                    pass
                elif mode == "rtt-idle":
                    pass # A passive RTT getter must not generate requests.
                elif mode == "interactive":
                    time.sleep(0.2)
                    sock.sendall(update())
                elif stage == 1:
                    rectangles = [rect(2, 1, 2, 1, 1, struct.pack("!HH", 0, 0))]
                    if mode == 'tight':
                        rectangles.append(rect(0, 2, 1, 1, 7, b'\x80\xff\x80\x00'))
                    sock.sendall(update(*rectangles))
                    stage += 1
                elif stage == 2:
                    width, height = 8, 4
                    image = pixels(width, height, (0, 0, 255))[:-4] + pixel(255, 255, 0)
                    sock.sendall(update(rect(0, 0, width, height, -223), rect(0, 0, width, height, 0, image)))
                    stage += 1
            elif message == 4:
                down, key = struct.unpack("!B2xI", read_exact(sock, 7))
                self.server.log(self.connection_id, "key", down=down, key=key,
                                during_slow=slow_pending.is_set(), at=time.monotonic())
            elif message == 5:
                mask, x, y = struct.unpack("!BHH", read_exact(sock, 5))
                self.server.log(self.connection_id, "pointer", mask=mask, x=x, y=y,
                                during_slow=slow_pending.is_set(), at=time.monotonic())
            elif message == 6:
                length = struct.unpack("!3xI", read_exact(sock, 7))[0]
                if length > 1024 * 1024:
                    raise ValueError("Unexpected clipboard length")
                value = read_exact(sock, length).decode("latin1")
                self.server.log(self.connection_id, "clipboard", text=value)
            else:
                raise ValueError("Unknown client message %s" % message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=5901)
    parser.add_argument("--scenario", choices=("frames", "tight", "jpeg", "password", "auth-fail", "stall", "oversize", "drop", "interactive",
                        "slow-small", "slow-large", "slow-capabilities", "slow-view-only", "slow-cancel", "slow-drop", "rtt-idle"), default="frames")
    parser.add_argument("--interactive", action="store_true")
    parser.add_argument("--info", type=Path)
    parser.add_argument("--events", type=Path)
    args = parser.parse_args()
    if args.interactive:
        args.scenario = "interactive"
    with Server(("127.0.0.1", args.port), args) as server:
        info = {"port": server.server_address[1], "scenario": args.scenario}
        if args.info:
            args.info.write_text(json.dumps(info))
        print("Local mock VNC: 127.0.0.1:%s (%s)" % (info["port"], args.scenario), flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
