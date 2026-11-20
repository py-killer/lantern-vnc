// SPDX-License-Identifier: GPL-2.0-or-later
// Runs against a test-owned offscreen window, synthetic frame data, and local
// events only. No VNC server, screen recording, accessibility, or global input.
import AppKit
import MetalKit
import Foundation

private final class RenderCapture: NSObject, MTKViewDelegate {
    let desktop: MetalDesktop
    var drawable: CAMetalDrawable?
    init(_ desktop: MetalDesktop) { self.desktop = desktop }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        desktop.mtkView(view, drawableSizeWillChange: size)
    }
    func draw(in view: MTKView) {
        drawable = view.currentDrawable
        desktop.draw(in: view)
    }
}

private final class TestScrollEvent: NSEvent {
    var point = CGPoint.zero
    var dx: CGFloat = 0
    var dy: CGFloat = 0
    override var type: NSEvent.EventType { .scrollWheel }
    override var locationInWindow: NSPoint { point }
    override var scrollingDeltaX: CGFloat { dx }
    override var scrollingDeltaY: CGFloat { dy }
    override var hasPreciseScrollingDeltas: Bool { true }
    override var modifierFlags: NSEvent.ModifierFlags { [] }
}
private final class TestMagnifyEvent: NSEvent {
    var point = CGPoint.zero
    var value: CGFloat = 0
    override var type: NSEvent.EventType { .magnify }
    override var locationInWindow: NSPoint { point }
    override var magnification: CGFloat { value }
    override var modifierFlags: NSEvent.ModifierFlags { [] }
}

private struct Snapshot {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let buffer: MTLBuffer
    func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        precondition(x >= 0 && y >= 0 && x < width && y < height)
        let bytes = buffer.contents().assumingMemoryBound(to: UInt8.self)
        let index = y * bytesPerRow + x * 4
        return (Int(bytes[index + 2]), Int(bytes[index + 1]), Int(bytes[index]))
    }
    func save(_ url: URL) throws {
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32)!
        let source = buffer.contents().assumingMemoryBound(to: UInt8.self)
        let target = image.bitmapData!
        for y in 0..<height {
            for x in 0..<width {
                let si = y * bytesPerRow + x * 4, ti = (y * width + x) * 4
                target[ti] = source[si + 2]; target[ti + 1] = source[si + 1]
                target[ti + 2] = source[si]; target[ti + 3] = 255
            }
        }
        try image.representation(using: .png, properties: [:])!.write(to: url)
    }
}

@main
struct NativeDisplayHarness {
    private static var checks = 0
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else { fatalError("Native display harness: \(message)") }
    }
    private static func settle(_ seconds: TimeInterval = 0.08) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
    }
    private static func color(_ actual: (Int, Int, Int), _ expected: (Int, Int, Int), _ label: String) {
        expect(abs(actual.0 - expected.0) < 12 && abs(actual.1 - expected.1) < 12 && abs(actual.2 - expected.2) < 12,
            "\(label): got RGB\(actual), expected RGB\(expected)")
    }
    private static func makeFrame(width: Int, height: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let rgb: (UInt8, UInt8, UInt8)
                if x == width - 1 && y == height - 1 { rgb = (255,255,255) }
                else if x == width - 1 { rgb = (255,0,255) }
                else if y == height - 1 { rgb = (0,255,255) }
                else if x >= 100 && x < 116 && y >= 100 && y < 116 {
                    let value: UInt8 = x % 2 == 0 ? 255 : 0
                    rgb = (value, value, value)
                } else if y < height / 2 { rgb = x < width / 2 ? (240, 32, 32) : (32, 220, 64) }
                else { rgb = x < width / 2 ? (32, 64, 240) : (240, 220, 32) }
                let p = (y * width + x) * 4
                bytes[p] = rgb.2; bytes[p + 1] = rgb.1; bytes[p + 2] = rgb.0; bytes[p + 3] = 0
            }
        }
        return bytes
    }
    private static func snapshot(_ desktop: MetalDesktop, _ capture: RenderCapture) -> Snapshot {
        settle()
        desktop.draw()
        guard let drawable = capture.drawable, let device = desktop.device,
              let queue = device.makeCommandQueue() else { fatalError("No Metal drawable; run on a Mac with an accessible WindowServer/Metal device") }
        // The renderer queues its real command buffer before returning. Wait
        // for the owned window's present to complete, without capturing any
        // screen or observing another application's UI.
        let deadline = Date(timeIntervalSinceNow: 2)
        while drawable.presentedTime == 0 && Date() < deadline { settle(0.02) }
        let texture = drawable.texture
        let row = ((texture.width * 4 + 255) / 256) * 256
        let buffer = device.makeBuffer(length: row * texture.height, options: .storageModeShared)!
        let command = queue.makeCommandBuffer()!
        let blit = command.makeBlitCommandEncoder()!
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                  to: buffer, destinationOffset: 0, destinationBytesPerRow: row,
                  destinationBytesPerImage: row * texture.height)
        blit.endEncoding(); command.commit(); command.waitUntilCompleted()
        expect(command.status == .completed, "GPU readback completed")
        return Snapshot(width: texture.width, height: texture.height, bytesPerRow: row, buffer: buffer)
    }
    private static func pixel(_ point: CGPoint, in snapshot: Snapshot, desktop: MetalDesktop) -> (Int, Int) {
        let sx = CGFloat(snapshot.width) / desktop.bounds.width
        let sy = CGFloat(snapshot.height) / desktop.bounds.height
        return (max(0,min(snapshot.width - 1,Int((point.x * sx).rounded(.down)))) ,
                max(0,min(snapshot.height - 1,Int((point.y * sy).rounded(.down)))))
    }
    private static func remoteColor(_ remote: CGPoint, expected: (Int, Int, Int), label: String,
                                    snapshot: Snapshot, desktop: MetalDesktop) {
        let view = desktop.currentViewport.viewPoint(forRemote: remote)
        expect(desktop.bounds.contains(view), "\(label) sample remains visible")
        let p = pixel(view, in: snapshot, desktop: desktop)
        color(snapshot.rgb(p.0, p.1), expected, label)
    }
    private static func mouse(_ type: NSEvent.EventType, _ point: CGPoint, desktop: MetalDesktop, window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: desktop.convert(point, to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }
    static func main() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            fputs("UNAVAILABLE: Metal access is required for native display checks (exit 77). Run on a Mac with GPU and WindowServer access.\n", stderr)
            exit(77)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "work/native-display", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 500, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        window.contentView = host
        let desktop = try MetalDesktop()
        desktop.attach(to: host)
        desktop.framebufferOnly = false // Enable readback solely for this test instance.
        let capture = RenderCapture(desktop)
        desktop.delegate = capture
        window.orderFront(nil)
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        host.layoutSubtreeIfNeeded()
        settle()
        print("ENV: macOS=\(ProcessInfo.processInfo.operatingSystemVersionString); GPU=\(desktop.device?.name ?? "Unknown"); backingScale=\(window.backingScaleFactor)")
        var pointers: [(Int32, Int32, Int32)] = []
        desktop.onPointer = { pointers.append(($0, $1, $2)) }
        let remote = CGSize(width: 1600, height: 1200)
        let bytes = makeFrame(width: Int(remote.width), height: Int(remote.height))
        bytes.withUnsafeBufferPointer { desktop.receive($0.baseAddress!, width: Int(remote.width), height: Int(remote.height), stride: Int(remote.width) * 4) }
        desktop.zoomMode = .fit
        var image = snapshot(desktop, capture)
        expect(desktop.remoteSize == remote, "received synthetic remote size")
        expect(abs(desktop.bounds.width - host.bounds.width) < 20 && abs(desktop.bounds.height - host.bounds.height) < 20,
               "Metal drawable remains viewport-sized rather than remote-desktop-sized")
        let corners: [(CGPoint, (Int, Int, Int), String)] = [
            (CGPoint(x: 40, y: 40), (240,32,32), "top-left red"),
            (CGPoint(x: 1560, y: 40), (32,220,64), "top-right green"),
            (CGPoint(x: 40, y: 1160), (32,64,240), "bottom-left blue"),
            (CGPoint(x: 1560, y: 1160), (240,220,32), "bottom-right yellow")]
        for (point, rgb, label) in corners { remoteColor(point, expected: rgb, label: "fit \(label)", snapshot: image, desktop: desktop) }
        try image.save(output.appendingPathComponent("fit-wide.png"))

        // Local window resizing must change the viewport only, preserve aspect,
        // retain orientation, and never issue a remote resize operation.
        for size in [CGSize(width: 350, height: 420), CGSize(width: 720, height: 260), CGSize(width: 500, height: 300)] {
            window.setContentSize(size); host.layoutSubtreeIfNeeded(); settle()
            image = snapshot(desktop, capture)
            expect(desktop.remoteSize == remote, "window resize leaves remote dimensions unchanged")
            let rect = desktop.currentViewport.imageRect
            expect(abs(rect.width / rect.height - 4.0 / 3.0) < 0.0001, "nonsquare window resize preserves image aspect")
            for (point, rgb, label) in corners { remoteColor(point, expected: rgb, label: "resized fit \(label)", snapshot: image, desktop: desktop) }
        }
        try image.save(output.appendingPathComponent("fit-resized.png"))

        desktop.zoomMode = .scale(1)
        expect(desktop.canPan, "100% large remote image has navigable overflow")
        for (index, item) in corners.enumerated() {
            desktop.setScrollFraction(x: index % 2 == 0 ? 0 : 1, y: index < 2 ? 0 : 1)
            image = snapshot(desktop, capture)
            remoteColor(item.0, expected: item.1, label: "100% panned \(item.2)", snapshot: image, desktop: desktop)
            try image.save(output.appendingPathComponent("actual-corner-\(index).png"))
        }
        desktop.setScrollFraction(x: 0, y: 0)
        image = snapshot(desktop, capture)
        for x in 100..<116 {
            let p = desktop.currentViewport.viewPoint(forRemote: CGPoint(x: x, y: 110))
            let location = pixel(p, in: image, desktop: desktop)
            let value = x % 2 == 0 ? 255 : 0
            color(image.rgb(location.0, location.1), (value,value,value), "physical one-pixel stripe \(x)")
        }

        // Native local event routing: hand drag/wheel pan even in view-only,
        // whereas normal mode emits remote button/wheel messages.
        desktop.setScrollFraction(x: 0.5, y: 0.5)
        desktop.panMode = true
        desktop.viewOnly = true
        let center = CGPoint(x: desktop.bounds.midX, y: desktop.bounds.midY)
        let beforeDrag = desktop.currentViewport.pan
        let countBefore = pointers.count
        desktop.mouseDown(with: mouse(.leftMouseDown, center, desktop: desktop, window: window))
        desktop.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: center.x - 40, y: center.y - 30), desktop: desktop, window: window))
        desktop.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: center.x - 40, y: center.y - 30), desktop: desktop, window: window))
        expect(desktop.currentViewport.pan.x > beforeDrag.x && desktop.currentViewport.pan.y > beforeDrag.y,
               "hand drag pans locally in both directions while view-only")
        expect(pointers.count == countBefore, "hand drag never sends remote input")
        let wheel = TestScrollEvent()
        wheel.point = desktop.convert(center, to: nil); wheel.dx = -20; wheel.dy = -15
        let beforeWheel = desktop.currentViewport.pan
        desktop.scrollWheel(with: wheel)
        expect(desktop.currentViewport.pan != beforeWheel, "hand-mode wheel pans local image")
        expect(pointers.count == countBefore, "hand-mode wheel never scrolls remote desktop")

        desktop.panMode = false
        desktop.viewOnly = false
        let mapped = desktop.currentViewport.remotePoint(at: center)!
        desktop.mouseDown(with: mouse(.leftMouseDown, center, desktop: desktop, window: window))
        desktop.mouseUp(with: mouse(.leftMouseUp, center, desktop: desktop, window: window))
        expect(pointers.count >= countBefore + 2, "normal-mode mouse emits remote press and release")
        let click = pointers[pointers.count - 2]
        expect(abs(CGFloat(click.0) - mapped.x) < 1.1 && abs(CGFloat(click.1) - mapped.y) < 1.1 && click.2 & 1 != 0,
               "remote mouse coordinates use same panned transform as renderer")
        let beforeRemoteWheel = pointers.count
        wheel.dx = 0; wheel.dy = 20
        desktop.scrollWheel(with: wheel)
        expect(pointers.count > beforeRemoteWheel, "normal-mode wheel reaches remote desktop")

        desktop.setScrollFraction(x: 0.5, y: 0.5)
        let anchor = CGPoint(x: desktop.bounds.midX - 10, y: desktop.bounds.midY - 10)
        let remoteAnchor = desktop.currentViewport.remotePoint(at: anchor)!
        let previousScale = desktop.displayScale
        let magnify = TestMagnifyEvent()
        magnify.point = desktop.convert(anchor, to: nil); magnify.value = 0.25
        desktop.magnify(with: magnify)
        let afterAnchor = desktop.currentViewport.remotePoint(at: anchor)!
        expect(desktop.displayScale > previousScale, "pinch magnification increases local zoom")
        expect(abs(afterAnchor.x - remoteAnchor.x) < 2 && abs(afterAnchor.y - remoteAnchor.y) < 2,
               "pinch zoom retains remote point beneath gesture anchor")
        expect(desktop.remoteSize == remote, "all local navigation leaves remote resolution unchanged")
        image = snapshot(desktop, capture)
        try image.save(output.appendingPathComponent("zoomed-panned.png"))

        // A 5K ultrawide surface exercises the original navigation failure:
        // the remote image is much larger than the Metal drawable at 100%.
        let wide = makeFrame(width: 5120, height: 1440)
        wide.withUnsafeBufferPointer { desktop.receive($0.baseAddress!, width: 5120, height: 1440, stride: 5120 * 4) }
        desktop.zoomMode = .fit
        image = snapshot(desktop, capture)
        expect(desktop.remoteSize == CGSize(width: 5120, height: 1440), "new server frame adopts its actual ultrawide dimensions")
        expect(abs(desktop.currentViewport.imageSize.width / desktop.currentViewport.imageSize.height - 5120.0 / 1440.0) < 0.0001,
               "5K ultrawide fit preserves aspect ratio")
        let wideCorners: [(CGPoint, (Int, Int, Int), String)] = [
            (CGPoint(x: 40, y: 40), (240,32,32), "ultrawide top-left"),
            (CGPoint(x: 5080, y: 40), (32,220,64), "ultrawide top-right"),
            (CGPoint(x: 40, y: 1400), (32,64,240), "ultrawide bottom-left"),
            (CGPoint(x: 5080, y: 1400), (240,220,32), "ultrawide bottom-right")]
        for (point, rgb, label) in wideCorners { remoteColor(point, expected: rgb, label: "fit \(label)", snapshot: image, desktop: desktop) }
        try image.save(output.appendingPathComponent("ultrawide-fit.png"))
        desktop.zoomMode = .scale(1)
        for (index, item) in wideCorners.enumerated() {
            desktop.setScrollFraction(x: index % 2 == 0 ? 0 : 1, y: index < 2 ? 0 : 1)
            image = snapshot(desktop, capture)
            remoteColor(item.0, expected: item.1, label: "100% \(item.2)", snapshot: image, desktop: desktop)
        }
        try image.save(output.appendingPathComponent("ultrawide-actual-bottom-right.png"))

        // Match the user's actual 5120 x 2880 remote desktop at two realistic
        // local window sizes. Scrollbar actions, not just model calls, must
        // move the image and update hit testing all the way to its last pixel.
        let fiveK = makeFrame(width: 5120, height: 2880)
        fiveK.withUnsafeBufferPointer { desktop.receive($0.baseAddress!, width: 5120, height: 2880, stride: 5120 * 4) }
        let fiveKCorners: [(CGPoint, (Int, Int, Int), String)] = [
            (CGPoint(x: 40, y: 40), (240,32,32), "5K top-left"),
            (CGPoint(x: 5080, y: 40), (32,220,64), "5K top-right"),
            (CGPoint(x: 40, y: 2840), (32,64,240), "5K bottom-left"),
            (CGPoint(x: 5080, y: 2840), (240,220,32), "5K bottom-right")]
        func findScroller(_ identifier: String, in view: NSView) -> NSScroller? {
            if let scroller = view as? NSScroller, scroller.identifier?.rawValue == identifier { return scroller }
            for child in view.subviews { if let found = findScroller(identifier, in: child) { return found } }
            return nil
        }
        for size in [CGSize(width: 860, height: 540), CGSize(width: 1180, height: 760)] {
            window.setContentSize(size); host.layoutSubtreeIfNeeded(); settle()
            desktop.zoomMode = .scale(1)
            image = snapshot(desktop, capture)
            guard let horizontal = findScroller("desktopHorizontalScroll", in: host),
                  let vertical = findScroller("desktopVerticalScroll", in: host) else { fatalError("Missing native viewport scrollbars") }
            expect(!horizontal.isHidden && !vertical.isHidden, "both native scrollbars are visible for the 5K desktop")
            expect(horizontal.frame.width > horizontal.frame.height && vertical.frame.height > vertical.frame.width,
                   "native scrollbar orientations match their axes")
            for (index, item) in fiveKCorners.enumerated() {
                horizontal.doubleValue = index % 2 == 0 ? 0 : 1
                expect(horizontal.sendAction(horizontal.action, to: horizontal.target), "horizontal scrollbar action is wired")
                vertical.doubleValue = index < 2 ? 0 : 1
                expect(vertical.sendAction(vertical.action, to: vertical.target), "vertical scrollbar action is wired")
                image = snapshot(desktop, capture)
                remoteColor(item.0, expected: item.1, label: "native scrollbar \(item.2)", snapshot: image, desktop: desktop)
                let p = desktop.currentViewport.viewPoint(forRemote: item.0)
                let prior = pointers.count
                desktop.mouseDown(with: mouse(.leftMouseDown, p, desktop: desktop, window: window))
                desktop.mouseUp(with: mouse(.leftMouseUp, p, desktop: desktop, window: window))
                expect(pointers.count == prior + 2, "5K panned corner emits mouse press and release")
                expect(abs(CGFloat(pointers[prior].0) - item.0.x) <= 1 && abs(CGFloat(pointers[prior].1) - item.0.y) <= 1,
                       "5K panned corner pointer agrees with rendered pixels")
            }
            remoteColor(CGPoint(x: 5119, y: 2879), expected: (255,255,255), label: "last remote pixel is reachable", snapshot: image, desktop: desktop)
            remoteColor(CGPoint(x: 5080, y: 2879), expected: (0,255,255), label: "last remote row is reachable", snapshot: image, desktop: desktop)
            remoteColor(CGPoint(x: 5119, y: 2840), expected: (255,0,255), label: "last remote column is reachable", snapshot: image, desktop: desktop)
        }
        try image.save(output.appendingPathComponent("5k-actual-bottom-right.png"))
        desktop.zoomMode = .fit
        for iteration in 0..<40 {
            let size = CGSize(width: 550 + (iteration * 83) % 700, height: 320 + (iteration * 61) % 630)
            window.setContentSize(size); host.layoutSubtreeIfNeeded()
            image = snapshot(desktop, capture)
            let rect = desktop.currentViewport.imageRect
            expect(abs(rect.width / rect.height - 16.0 / 9.0) < 0.0001, "resize stress \(iteration) keeps 5K image aspect")
            expect(desktop.remoteSize == CGSize(width: 5120, height: 2880), "resize stress \(iteration) never changes server dimensions")
            for (point, rgb, label) in fiveKCorners {
                remoteColor(point, expected: rgb, label: "resize stress \(iteration) \(label)", snapshot: image, desktop: desktop)
            }
        }
        try image.save(output.appendingPathComponent("5k-resize-stress-final.png"))
        let report: [String: Any] = [
            "appVersion": ProcessInfo.processInfo.environment["LANTERN_TEST_VERSION"] ?? "working tree",
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "gpu": desktop.device?.name ?? "Unknown",
            "backingScale": window.backingScaleFactor,
            "nativeChecks": checks,
            "remoteSizes": ["1600x1200", "5120x1440", "5120x2880"],
            "resizeStressIterations": 40,
            "inputSource": "generated frames and events in an owned offscreen window",
            "manualHardwareMatrix": "not run"
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("native-display-report.json"))
        window.orderOut(nil)
        print("PASS: \(checks) native Metal readback and event-routing checks; screenshots in \(output.path)")
    }
}
