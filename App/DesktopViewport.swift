// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import CoreGraphics

enum DesktopZoomMode: Equatable {
    case automatic
    case fit
    /// Remote pixels per macOS drawable/backing pixel. 1 means 100%.
    case scale(Double)
}

/// The only transform used for both rendering and remote pointer coordinates.
/// All view/pan values are AppKit points; remote dimensions are RFB pixels.
struct DesktopViewport {
    private(set) var remoteSize: CGSize
    private(set) var viewportSize: CGSize
    private(set) var backingScale: CGFloat
    private(set) var zoomMode: DesktopZoomMode
    private(set) var pan: CGPoint = .zero

    init(remoteSize: CGSize = .zero, viewportSize: CGSize = .zero,
         backingScale: CGFloat = 2, zoomMode: DesktopZoomMode = .automatic) {
        self.remoteSize = Self.validSize(remoteSize)
        self.viewportSize = Self.validSize(viewportSize)
        self.backingScale = Self.validBacking(backingScale)
        self.zoomMode = zoomMode
    }

    var displayScale: CGFloat {
        guard remoteSize.width > 0, remoteSize.height > 0,
              viewportSize.width > 0, viewportSize.height > 0 else { return 1 }
        let fit = min(viewportSize.width * backingScale / remoteSize.width,
                      viewportSize.height * backingScale / remoteSize.height)
        switch zoomMode {
        case .fit: return fit
        case .automatic: return max(1, min(fit, 2))
        case .scale(let value): return value.isFinite ? max(0.1, min(CGFloat(value), 4)) : 1
        }
    }
    var pointScale: CGFloat { displayScale / backingScale }
    var imageSize: CGSize {
        CGSize(width: remoteSize.width * pointScale, height: remoteSize.height * pointScale)
    }
    var maxPan: CGPoint {
        CGPoint(x: max(0, imageSize.width - viewportSize.width),
                y: max(0, imageSize.height - viewportSize.height))
    }
    var canPan: Bool { maxPan.x > 0.01 || maxPan.y > 0.01 }
    var imageRect: CGRect {
        let size = imageSize
        // At 100%, integer backing-pixel origins avoid half-pixel sampling blur.
        let x = size.width < viewportSize.width ? snapped((viewportSize.width-size.width)/2) : -pan.x
        let y = size.height < viewportSize.height ? snapped((viewportSize.height-size.height)/2) : -pan.y
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    mutating func setRemoteSize(_ size: CGSize) {
        guard remoteSize != Self.validSize(size) else { return }
        let anchor = centerRemotePoint
        remoteSize = Self.validSize(size)
        if let anchor = anchor { center(on: anchor) } else { pan = .zero }
        clampPan()
    }
    mutating func setViewportSize(_ size: CGSize, backingScale: CGFloat) {
        guard viewportSize != Self.validSize(size) || self.backingScale != Self.validBacking(backingScale) else { return }
        let anchor = centerRemotePoint
        viewportSize = Self.validSize(size)
        self.backingScale = Self.validBacking(backingScale)
        if let anchor = anchor { center(on: anchor) }
        clampPan()
    }
    mutating func setZoomMode(_ mode: DesktopZoomMode, anchor: CGPoint? = nil) {
        let viewAnchor = anchor ?? CGPoint(x: viewportSize.width/2, y: viewportSize.height/2)
        let remoteAnchor = unboundedRemotePoint(at: viewAnchor)
        zoomMode = mode
        if let remoteAnchor = remoteAnchor {
            pan = CGPoint(x: remoteAnchor.x*pointScale-viewAnchor.x,
                          y: remoteAnchor.y*pointScale-viewAnchor.y)
        }
        clampPan()
    }
    mutating func panBy(dx: CGFloat, dy: CGFloat) {
        guard dx.isFinite, dy.isFinite else { return }
        setPan(CGPoint(x: pan.x+dx, y: pan.y+dy))
    }
    mutating func setPan(_ value: CGPoint) {
        guard value.x.isFinite, value.y.isFinite else { return }
        pan = value
        clampPan()
    }
    mutating func setScrollFraction(x: Double? = nil, y: Double? = nil) {
        var next = pan
        if let x = x, x.isFinite { next.x = CGFloat(max(0,min(1,x)))*maxPan.x }
        if let y = y, y.isFinite { next.y = CGFloat(max(0,min(1,y)))*maxPan.y }
        setPan(next)
    }

    func remotePoint(at point: CGPoint, clamp: Bool = false) -> CGPoint? {
        guard point.x.isFinite, point.y.isFinite,
              remoteSize.width > 0, remoteSize.height > 0,
              pointScale > 0 else { return nil }
        guard clamp || imageRect.contains(point) else { return nil }
        guard let p = unboundedRemotePoint(at: point) else { return nil }
        return CGPoint(x: max(0,min(remoteSize.width-1,p.x)),
                       y: max(0,min(remoteSize.height-1,p.y)))
    }
    func viewPoint(forRemote point: CGPoint) -> CGPoint {
        CGPoint(x: imageRect.minX + point.x*pointScale,
                y: imageRect.minY + point.y*pointScale)
    }

    private var centerRemotePoint: CGPoint? {
        unboundedRemotePoint(at: CGPoint(x: viewportSize.width/2,y: viewportSize.height/2))
    }
    private func unboundedRemotePoint(at point: CGPoint) -> CGPoint? {
        guard remoteSize.width > 0, remoteSize.height > 0, pointScale > 0 else { return nil }
        return CGPoint(x:(point.x-imageRect.minX)/pointScale,
                       y:(point.y-imageRect.minY)/pointScale)
    }
    private mutating func center(on remotePoint: CGPoint) {
        pan = CGPoint(x:remotePoint.x*pointScale-viewportSize.width/2,
                      y:remotePoint.y*pointScale-viewportSize.height/2)
    }
    private mutating func clampPan() {
        let limit = maxPan
        pan.x = max(0,min(limit.x,snapped(pan.x)))
        pan.y = max(0,min(limit.y,snapped(pan.y)))
        if case .fit = zoomMode { pan = .zero }
    }
    private func snapped(_ value: CGFloat) -> CGFloat { (value*backingScale).rounded()/backingScale }
    private static func validSize(_ value: CGSize) -> CGSize {
        CGSize(width:value.width.isFinite ? max(0,value.width) : 0,
               height:value.height.isFinite ? max(0,value.height) : 0)
    }
    private static func validBacking(_ value: CGFloat) -> CGFloat {
        value.isFinite && value > 0 ? value : 1
    }
}
