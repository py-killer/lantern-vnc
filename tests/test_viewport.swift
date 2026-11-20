// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import CoreGraphics

@main
struct DesktopViewportTests {
    private static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else { fatalError("Viewport test failed: \(message)") }
    }
    static func near(_ actual: CGFloat, _ expected: CGFloat, _ message: String, tolerance: CGFloat = 0.00001) {
        expect(actual.isFinite && abs(actual - expected) <= tolerance,
               "\(message): got \(actual), expected \(expected)")
    }
    static func samePoint(_ actual: CGPoint?, _ expected: CGPoint, _ message: String, tolerance: CGFloat = 0.00001) {
        guard let actual = actual else { fatalError("Viewport test failed: \(message) returned nil") }
        near(actual.x, expected.x, message + " x", tolerance: tolerance)
        near(actual.y, expected.y, message + " y", tolerance: tolerance)
    }
    static func main() {
        var empty = DesktopViewport()
        expect(empty.remotePoint(at: .zero) == nil, "empty viewport rejects remote input")
        empty.panBy(dx: 100, dy: -100)
        expect(!empty.canPan, "empty viewport cannot pan")
        expect(empty.imageRect.width.isFinite && empty.imageRect.height.isFinite, "empty image geometry stays finite")

        // Automatic mode never shrinks a large remote screen below one physical
        // pixel per remote pixel, and never enlarges a small desktop beyond 2x.
        var automatic = DesktopViewport(remoteSize: CGSize(width: 3840, height: 2160),
            viewportSize: CGSize(width: 800, height: 600), backingScale: 2)
        near(automatic.displayScale, 1, "automatic large desktop starts at physical 100%")
        expect(automatic.canPan, "large desktop is navigable without reducing readability")
        automatic.setRemoteSize(CGSize(width: 320, height: 200))
        near(automatic.displayScale, 2, "automatic small desktop enlargement is capped")
        automatic.setRemoteSize(CGSize(width: 1200, height: 800))
        near(automatic.displayScale, 4.0 / 3.0, "automatic chooses intermediate fit zoom")

        var fit = DesktopViewport(remoteSize: CGSize(width: 1920, height: 1080),
            viewportSize: CGSize(width: 800, height: 600), backingScale: 2, zoomMode: .fit)
        near(fit.imageRect.minX, 0, "wide fit starts at left")
        near(fit.imageRect.minY, 75, "wide fit is vertically centered")
        near(fit.imageSize.width, 800, "fit fills available width")
        near(fit.imageSize.height, 450, "fit preserves remote aspect ratio")
        expect(!fit.canPan, "fit needs no pan")
        expect(fit.remotePoint(at: CGPoint(x: 100, y: 30)) == nil, "letterbox cannot send an accidental remote click")
        samePoint(fit.remotePoint(at: CGPoint(x: 100, y: 30), clamp: true), CGPoint(x: 240, y: 0), "drag outside image clamps to top edge")
        samePoint(fit.remotePoint(at: CGPoint(x: 400, y: 300)), CGPoint(x: 960, y: 540), "fit center hit test")

        // 100% describes physical pixels, independently of Retina backing scale.
        for backing: CGFloat in [1, 2, 3] {
            var actual = DesktopViewport(remoteSize: CGSize(width: 1600, height: 900),
                viewportSize: CGSize(width: 320, height: 240), backingScale: backing, zoomMode: .scale(1))
            actual.setPan(.zero)
            near(actual.imageSize.width * backing, 1600, "100% remote width in physical pixels at backing \(backing)")
            near(actual.imageSize.height * backing, 900, "100% remote height in physical pixels at backing \(backing)")
            near(actual.pointScale * backing, 1, "100% point conversion at backing \(backing)")
            let topLeft = actual.viewPoint(forRemote: CGPoint(x: 40, y: 60))
            samePoint(actual.remotePoint(at: topLeft), CGPoint(x: 40, y: 60), "100% pointer coordinates at backing \(backing)")
            let adjacent = actual.viewPoint(forRemote: CGPoint(x: 41, y: 60))
            near((adjacent.x - topLeft.x) * backing, 1, "adjacent remote pixels occupy exactly one display pixel")
        }

        var pan = DesktopViewport(remoteSize: CGSize(width: 4000, height: 2400),
            viewportSize: CGSize(width: 800, height: 600), backingScale: 2, zoomMode: .scale(1))
        pan.setPan(.zero)
        near(pan.maxPan.x, 1200, "horizontal overflow in points")
        near(pan.maxPan.y, 600, "vertical overflow in points")
        pan.panBy(dx: 300, dy: 200)
        samePoint(pan.remotePoint(at: .zero), CGPoint(x: 600, y: 400), "pan shifts pointer mapping with image")
        near(pan.imageRect.minX, -300, "horizontal pan changes image translation")
        near(pan.imageRect.minY, -200, "vertical pan changes image translation")
        pan.panBy(dx: 100000, dy: 100000)
        near(pan.pan.x, pan.maxPan.x, "pan clamps right")
        near(pan.pan.y, pan.maxPan.y, "pan clamps bottom")
        pan.panBy(dx: -100000, dy: -100000)
        near(pan.pan.x, 0, "pan clamps left")
        near(pan.pan.y, 0, "pan clamps top")
        pan.setScrollFraction(x: 1, y: 0.5)
        near(pan.pan.x, 1200, "horizontal scrollbar reaches right edge")
        near(pan.pan.y, 300, "vertical scrollbar midpoint")
        pan.setScrollFraction(x: -1, y: 4)
        near(pan.pan.x, 0, "negative scrollbar value clamps")
        near(pan.pan.y, 600, "overflow scrollbar value clamps")
        pan.setPan(CGPoint(x: 100.13, y: 70.39))
        near(pan.pan.x * 2, (pan.pan.x * 2).rounded(), "pan x snapped to physical pixel")
        near(pan.pan.y * 2, (pan.pan.y * 2).rounded(), "pan y snapped to physical pixel")

        // A zoom anchored away from edges must retain the same remote position
        // under the pointer. These values avoid unavoidable pan-bound clamping.
        var zoom = DesktopViewport(remoteSize: CGSize(width: 2000, height: 1600),
            viewportSize: CGSize(width: 400, height: 300), backingScale: 2, zoomMode: .scale(1))
        zoom.setPan(CGPoint(x: 200, y: 150))
        let anchor = CGPoint(x: 180, y: 120)
        let beneath = zoom.remotePoint(at: anchor)!
        zoom.setZoomMode(.scale(2), anchor: anchor)
        samePoint(zoom.remotePoint(at: anchor), beneath, "pinch zoom keeps pointer anchor fixed")
        near(zoom.displayScale, 2, "custom 200% zoom")
        zoom.setZoomMode(.scale(1), anchor: anchor)
        samePoint(zoom.remotePoint(at: anchor), beneath, "reverse zoom restores pointer anchor")
        let serverResolution = zoom.remoteSize
        zoom.setViewportSize(CGSize(width: 610, height: 420), backingScale: 2)
        zoom.setZoomMode(.fit)
        zoom.panBy(dx: 300, dy: 200)
        expect(zoom.remoteSize == serverResolution, "local resize/zoom/pan never changes server resolution")
        expect(zoom.pan == .zero, "fit clears overflowing pan")

        // Regression matrix for portrait/wide/square windows, odd remote sizes,
        // backing changes, and repeated zoom/resizes. All tests use public
        // geometric invariants rather than copying the model implementation.
        let remoteSizes = [CGSize(width: 320, height: 200), CGSize(width: 1001, height: 777),
                           CGSize(width: 1080, height: 1920), CGSize(width: 5120, height: 1440)]
        let viewSizes = [CGSize(width: 300, height: 700), CGSize(width: 900, height: 300),
                         CGSize(width: 701, height: 501), CGSize(width: 1200, height: 900)]
        for remote in remoteSizes {
            for view in viewSizes {
                for backing: CGFloat in [1, 2] {
                    fit = DesktopViewport(remoteSize: remote, viewportSize: view, backingScale: backing, zoomMode: .fit)
                    near(fit.imageSize.width / fit.imageSize.height, remote.width / remote.height, "fit matrix preserves aspect")
                    expect(fit.imageSize.width <= view.width + 0.001 && fit.imageSize.height <= view.height + 0.001, "fit stays within viewport")
                    expect(abs(fit.imageSize.width - view.width) < 0.001 || abs(fit.imageSize.height - view.height) < 0.001, "fit touches at least one viewport extent")
                    fit.setZoomMode(.scale(1))
                    near(fit.imageSize.width * backing, remote.width, "100% matrix physical width")
                    near(fit.imageSize.height * backing, remote.height, "100% matrix physical height")
                    near(fit.imageRect.minX * backing, (fit.imageRect.minX * backing).rounded(), "100% origin x aligns to physical pixels")
                    near(fit.imageRect.minY * backing, (fit.imageRect.minY * backing).rounded(), "100% origin y aligns to physical pixels")
                    fit.setScrollFraction(x: 1, y: 1)
                    expect(fit.pan.x >= 0 && fit.pan.y >= 0 && fit.pan.x <= fit.maxPan.x + 0.001 && fit.pan.y <= fit.maxPan.y + 0.001, "pan remains bounded after zoom")
                    fit.setViewportSize(CGSize(width: view.height, height: view.width), backingScale: backing)
                    expect(fit.remoteSize == remote, "resize matrix preserves remote pixel dimensions")
                    near(fit.imageSize.width / fit.imageSize.height, remote.width / remote.height, "resize matrix preserves aspect")
                }
            }
        }
        print("PASS: \(checks) deterministic viewport geometry checks")
    }
}
