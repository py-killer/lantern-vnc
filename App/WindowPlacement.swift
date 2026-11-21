// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit

enum WindowPlacement {
    static let autosaveName = "LanternMainWindow"

    /// Returns whether a usable saved frame was restored. Register only after
    /// initial UI/layout work, which must not overwrite the previous session.
    @discardableResult
    static func restoreAndRegister(_ window: NSWindow, name: String = autosaveName) -> Bool {
        let restored = window.setFrameUsingName(name)
        let visibleFrames = NSScreen.screens.map { $0.visibleFrame }
        let usable = restored ? reachableFrame(window.frame, visibleFrames: visibleFrames, minimumSize: window.minSize) : nil
        if let frame = usable { window.setFrame(frame, display: false) }
        else { window.center() }
        let placement = window.frame
        window.setFrameAutosaveName(name)
        // AppKit versions can also restore when assigning an autosave name.
        // Preserve the resolved placement if registration reapplies old data.
        if window.frame != placement { window.setFrame(placement, display: false) }
        return usable != nil
    }

    static func save(_ window: NSWindow) {
        let name = window.frameAutosaveName
        guard !name.isEmpty, !window.styleMask.contains(.fullScreen) else { return }
        window.saveFrame(usingName: name)
    }

    /// Uses logical screen points. Preserve intentional partly offscreen or
    /// spanning windows when their title bar is reachable. Only repair frames
    /// that exceed the desktop or whose title bar is inaccessible.
    static func reachableFrame(_ frame: CGRect, visibleFrames: [CGRect], minimumSize: CGSize) -> CGRect? {
        guard isValid(frame) else { return nil }
        let minimumWidth = minimumSize.width.isFinite ? max(0, minimumSize.width) : 0
        let minimumHeight = minimumSize.height.isFinite ? max(0, minimumSize.height) : 0
        var candidate = frame
        candidate.size.width = max(candidate.width, minimumWidth)
        candidate.size.height = max(candidate.height, minimumHeight)
        guard isValid(candidate) else { return nil }
        let screens = visibleFrames.filter(isValid)
        guard let first = screens.first else { return candidate }
        let desktop = screens.dropFirst().reduce(first) { $0.union($1) }
        let titleHeight = min(32, candidate.height)
        let title = CGRect(x: candidate.minX, y: candidate.maxY-titleHeight,
                           width: candidate.width, height: titleHeight)
        let reachable = screens.contains { screen in
            let intersection = title.intersection(screen)
            return !intersection.isNull && intersection.width >= min(120, candidate.width) &&
                   intersection.height >= min(20, titleHeight)
        }
        if reachable && candidate.width <= desktop.width && candidate.height <= desktop.height { return candidate }

        // Prefer the screen containing most of the old window. A removed
        // monitor leaves no intersection, so choose the nearest surviving one.
        func distance(to screen: CGRect) -> CGFloat {
            let dx = candidate.midX-max(screen.minX,min(screen.maxX,candidate.midX))
            let dy = candidate.midY-max(screen.minY,min(screen.maxY,candidate.midY))
            return hypot(dx,dy)
        }
        let target = screens.dropFirst().reduce(first) { best, screen in
            let bestArea = area(candidate.intersection(best))
            let nextArea = area(candidate.intersection(screen))
            if nextArea > bestArea || (nextArea == bestArea && distance(to: screen) < distance(to: best)) { return screen }
            return best
        }
        candidate.size.width = min(candidate.width, target.width)
        candidate.size.height = min(candidate.height, target.height)
        candidate.origin.x = max(target.minX,min(target.maxX-candidate.width,candidate.minX))
        candidate.origin.y = max(target.minY,min(target.maxY-candidate.height,candidate.minY))
        return candidate
    }

    private static func isValid(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite && frame.width.isFinite && frame.height.isFinite &&
        frame.size.width > 0 && frame.size.height > 0 && frame.maxX.isFinite && frame.maxY.isFinite
    }
    private static func area(_ frame: CGRect) -> CGFloat {
        frame.isNull || frame.isEmpty ? 0 : frame.width*frame.height
    }
}
