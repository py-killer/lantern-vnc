// SPDX-License-Identifier: GPL-2.0-or-later
// Real Metal texture readback in an owned offscreen window. Synthetic pixels
// only: no VNC server, Keychain, screen recording, global input, or activation.
import AppKit
import MetalKit
import Foundation

private struct PixelOracle {
    let width: Int
    let height: Int
    var bytes: [UInt8]

    init(width: Int, height: Int, seed: UInt8) {
        self.width = width; self.height = height
        bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                bytes[i] = UInt8(truncatingIfNeeded: x * 13 + y * 7 + Int(seed))
                bytes[i + 1] = UInt8(truncatingIfNeeded: x * 3 + y * 17 + Int(seed))
                bytes[i + 2] = UInt8(truncatingIfNeeded: x * 19 + y * 5 + Int(seed))
                bytes[i + 3] = 255
            }
        }
    }

    mutating func paint(_ region: FrameRegion, value: UInt8) {
        for y in region.y..<(region.y + region.height) {
            for x in region.x..<(region.x + region.width) {
                let i = (y * width + x) * 4
                bytes[i] = value; bytes[i + 1] = value &+ 31
                bytes[i + 2] = value &+ 73; bytes[i + 3] = 255
            }
        }
    }

    func send(to desktop: MetalDesktop, dirty: FrameRegion? = nil) {
        bytes.withUnsafeBufferPointer {
            desktop.receive($0.baseAddress!, width: width, height: height, stride: width * 4, dirty: dirty)
        }
    }
}

@main
struct PerformanceDisplayHarness {
    private static var checks = 0
    private static var readbacks = 0
    private static var latest: FrameUpdateState?
    private static var seenSlots = Set<Int>()

    private static func expect(_ value: @autoclosure () -> Bool, _ label: String) {
        checks += 1
        guard value() else { fatalError("Performance display harness: \(label)") }
    }
    private static func settle(_ seconds: TimeInterval = 0.01) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
    }
    private static func compare(_ data: Data, oracle: PixelOracle, label: String) {
        expect(data.count == oracle.bytes.count, "\(label): tightly packed full texture readback")
        if !data.elementsEqual(oracle.bytes) {
            let difference = zip(data, oracle.bytes).enumerated().first { $0.element.0 != $0.element.1 }!
            fatalError("Performance display harness: \(label): pixel mismatch at byte \(difference.offset), got \(difference.element.0), expected \(difference.element.1)")
        }
        checks += 1
        readbacks += 1
    }

    @discardableResult
    private static func awaitFrame(_ desktop: MetalDesktop, slot: Int, oracle: PixelOracle,
                                   after prior: FrameUpdateState?, label: String) -> FrameUpdateState {
        let deadline = Date(timeIntervalSinceNow: 5)
        let targetSequence = desktop.framesReceived
        while Date() < deadline {
            desktop.draw()
            settle()
            guard let snapshot = desktop.testingTextureSnapshot(slot: slot) else { continue }
            let state = snapshot.state
            guard state.width == oracle.width && state.height == oracle.height else { continue }
            guard state.sequence >= targetSequence else { continue }
            if let prior = prior, state.generation == prior.generation && state.sequence <= prior.sequence { continue }
            compare(snapshot.data, oracle: oracle, label: label)
            latest = state; seenSlots.insert(slot)
            return state
        }
        fatalError("Performance display harness: timed out waiting for GPU-completed slot \(slot) (\(label))")
    }

    private static func update(_ desktop: MetalDesktop, slot: Int, oracle: PixelOracle,
                               dirty: FrameRegion?, label: String) {
        desktop.testingPreferredSlot = slot
        let prior = latest
        oracle.send(to: desktop, dirty: dirty)
        awaitFrame(desktop, slot: slot, oracle: oracle, after: prior, label: label)
    }

    static func main() throws {
        guard MTLCreateSystemDefaultDevice() != nil, !NSScreen.screens.isEmpty else {
            fputs("NOT RUN: Metal/WindowServer unavailable (exit 77); not a passing renderer test.\n", stderr)
            exit(77)
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "work/performance-display-tests", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 420, height: 280),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.ignoresMouseEvents = true
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 280))
        window.contentView = host
        let desktop = try MetalDesktop()
        desktop.attach(to: host)
        window.orderBack(nil); window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        host.layoutSubtreeIfNeeded(); settle(0.05)
        defer { window.orderOut(nil); window.close() }
        expect(!window.isKeyWindow, "owned offscreen window never takes keyboard focus")
        var oracle = PixelOracle(width: 64, height: 48, seed: 7)
        let origin = FrameRegion(x: 0, y: 0, width: 1, height: 1)
        let patch = FrameRegion(x: 9, y: 7, width: 3, height: 2)

        // A new slot needs the complete canonical image, even when its triggering
        // callback reports only one unchanged pixel.
        let firstBytes = desktop.textureUploadBytes, firstFull = desktop.fullTextureUploads
        for slot in 0..<3 {
            update(desktop, slot: slot, oracle: oracle, dirty: slot == 0 ? nil : origin, label: "warm slot \(slot)")
        }
        expect(seenSlots == Set(0..<3), "all three actual texture slots exercised")
        expect(desktop.fullTextureUploads - firstFull == 3, "each initially empty slot gets exactly one full initialization")
        expect(desktop.textureUploadBytes - firstBytes == 3 * oracle.bytes.count, "initialization uploads exactly three complete images")

        // Align each slot's outstanding history to one fixed tiny rectangle.
        // This makes the next rotation's byte cost exact, independent of earlier
        // bounding unions used to bring a stale slot up to date.
        for slot in 0..<3 {
            oracle.paint(patch, value: UInt8(40 + slot))
            update(desktop, slot: slot, oracle: oracle, dirty: patch, label: "align slot \(slot)")
        }
        let steadyBytes = desktop.textureUploadBytes, steadyFull = desktop.fullTextureUploads
        let steadyPartial = desktop.partialTextureUploads
        for iteration in 0..<12 {
            let before = desktop.textureUploadBytes
            oracle.paint(patch, value: UInt8(70 + iteration))
            update(desktop, slot: iteration % 3, oracle: oracle, dirty: patch, label: "steady patch \(iteration)")
            expect(desktop.textureUploadBytes - before == patch.width * patch.height * 4,
                   "steady small patch uploads only its six pixels on alternating slots")
        }
        expect(desktop.fullTextureUploads == steadyFull, "steady partial updates never fall back to full images")
        expect(desktop.partialTextureUploads - steadyPartial == 12, "each steady update is recorded as one partial upload")
        expect(desktop.textureUploadBytes - steadyBytes == 12 * patch.width * patch.height * 4,
               "steady-state measured transfer is area times four, not frame size")
        let measuredSteadyBytes = desktop.textureUploadBytes - steadyBytes

        // Disjoint/overlapping changes must survive skipped slots and coalescing.
        let regions = [FrameRegion(x: 2, y: 3, width: 5, height: 4),
                       FrameRegion(x: 54, y: 35, width: 7, height: 6),
                       FrameRegion(x: 4, y: 4, width: 6, height: 5),
                       FrameRegion(x: 63, y: 0, width: 1, height: 48),
                       FrameRegion(x: 0, y: 47, width: 64, height: 1)]
        for (index, region) in regions.enumerated() {
            oracle.paint(region, value: UInt8(110 + index))
            update(desktop, slot: (index + 1) % 3, oracle: oracle, dirty: region, label: "disjoint/edge patch \(index)")
        }
        let prior = latest
        desktop.testingPreferredSlot = 0
        for index in 0..<30 {
            let region = FrameRegion(x: 12 + index % 9, y: 15 + index % 7, width: 2, height: 2)
            oracle.paint(region, value: UInt8(150 + index))
            oracle.send(to: desktop, dirty: region)
        }
        awaitFrame(desktop, slot: 0, oracle: oracle, after: prior, label: "thirty coalesced callbacks")
        // Submit without yielding between updates. GPU work may still own a slot
        // when the next callback arrives; the final readback must include every
        // patch regardless of which individual draw attempts could proceed.
        let burstPrior = latest
        var busyObservations = 0
        for index in 0..<18 {
            let region = FrameRegion(x: 25 + index % 12, y: 26 + index % 9, width: 2, height: 2)
            desktop.testingPreferredSlot = index % 3
            oracle.paint(region, value: UInt8(181 + index))
            oracle.send(to: desktop, dirty: region)
            desktop.draw()
            if desktop.testingTextureSnapshot(slot: index % 3) == nil { busyObservations += 1 }
        }
        awaitFrame(desktop, slot: 2, oracle: oracle, after: burstPrior, label: "rapid in-flight patch submissions")
        // Catch up every slot; unchanged origin callbacks still advance revision.
        for slot in 0..<3 {
            update(desktop, slot: slot, oracle: oracle, dirty: origin, label: "catch-up slot \(slot)")
        }

        let redrawBytes = desktop.textureUploadBytes
        let redrawFull = desktop.fullTextureUploads, redrawPartial = desktop.partialTextureUploads
        window.setContentSize(NSSize(width: 90, height: 70)); host.layoutSubtreeIfNeeded()
        desktop.zoomMode = .scale(4)
        expect(desktop.canPan, "small owned viewport enables real panning")
        let beforePan = desktop.currentViewport.pan
        desktop.panBy(dx: 12, dy: 9)
        expect(desktop.currentViewport.pan != beforePan, "navigation redraw test actually moves the image")
        desktop.draw(); settle()
        for mode: DesktopZoomMode in [.fit, .scale(1), .scale(2), .automatic, .scale(0.75)] {
            desktop.zoomMode = mode
            desktop.panBy(dx: 12, dy: 9)
            desktop.draw(); settle()
        }
        window.setContentSize(NSSize(width: 420, height: 280)); host.layoutSubtreeIfNeeded()
        desktop.draw(); settle()
        expect(desktop.textureUploadBytes == redrawBytes && desktop.fullTextureUploads == redrawFull && desktop.partialTextureUploads == redrawPartial,
               "pan/zoom redraws with no new frame upload zero bytes")

        let generationBeforeClear = latest!.generation
        desktop.clear(); latest = nil; settle()
        expect(desktop.testingTextureSnapshot(slot: 0) == nil, "clear removes old same-size texture content")
        oracle = PixelOracle(width: 64, height: 48, seed: 203)
        var before = desktop.textureUploadBytes
        update(desktop, slot: 2, oracle: oracle, dirty: origin, label: "same-size reconnect full initialization")
        expect(latest!.generation != generationBeforeClear, "same-size reconnect advances generation")
        expect(desktop.textureUploadBytes - before == oracle.bytes.count, "same-size reconnect uploads one full image despite tiny dirty callback")
        for (index, size) in [(37, 53), (96, 72), (64, 48)].enumerated() {
            let oldGeneration = latest!.generation
            oracle = PixelOracle(width: size.0, height: size.1, seed: UInt8(220 + index))
            before = desktop.textureUploadBytes
            update(desktop, slot: index % 3, oracle: oracle, dirty: origin, label: "resize generation \(index)")
            expect(latest!.generation != oldGeneration, "each remote resize advances framebuffer generation")
            expect(desktop.textureUploadBytes - before == oracle.bytes.count, "resized texture uploads exactly one new full image")
            let edge = FrameRegion(x: oracle.width - 1, y: oracle.height - 1, width: 1, height: 1)
            oracle.paint(edge, value: UInt8(240 + index))
            update(desktop, slot: index % 3, oracle: oracle, dirty: edge, label: "resized last-pixel patch \(index)")
        }
        expect(!window.isKeyWindow, "renderer tests never activate the owned window")
        let report: [String: Any] = ["checks": checks, "fullPixelReadbacks": readbacks,
            "slotsExercised": seenSlots.sorted(), "steadyPatch": "3x2 BGRA pixels",
            "steadyUpdates": 12, "steadyUploadBytes": measuredSteadyBytes,
            "coalescedCallbacks": 30, "rapidSubmittedCallbacks": 18, "busySlotObservations": busyObservations,
            "textureUploadBytesSinceClear": desktop.textureUploadBytes,
            "fullTextureUploads": desktop.fullTextureUploads, "partialTextureUploads": desktop.partialTextureUploads,
            "gpu": desktop.device?.name ?? "Unknown", "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "scope": "owned offscreen window and generated pixels; no user credentials, global input, or LAN",
            "manualHardwareMatrix": "not run"]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("performance-display-report.json"))
        print("PASS: \(checks) Metal partial-upload checks; \(readbacks) full-pixel texture readbacks across all three slots")
    }
}
