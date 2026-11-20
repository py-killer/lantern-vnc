#!/usr/bin/env swift
import AppKit
import Foundation

// Original vector artwork for Lantern VNC. GPL-2.0-or-later.
let script = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let project = script.deletingLastPathComponent().deletingLastPathComponent()
let output = project.appendingPathComponent("App/AppIcon.icns")
let iconset = project.appendingPathComponent("build/AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}
func rounded(_ rect: NSRect, _ radius: CGFloat, _ fill: NSColor) {
    fill.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}
func drawIcon() {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x000000, alpha: 0.22)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    let tile = NSBezierPath(roundedRect: NSRect(x: 56, y: 56, width: 912, height: 912), xRadius: 205, yRadius: 205)
    NSGradient(starting: color(0x244650), ending: color(0x0C2029))!.draw(in: tile, angle: -65)
    NSGraphicsContext.restoreGraphicsState()

    // A second display gives the mark a clear remote-desktop silhouette.
    rounded(NSRect(x: 169, y: 408, width: 558, height: 334), 42, color(0x3A747B))
    rounded(NSRect(x: 183, y: 423, width: 530, height: 304), 29, color(0x18343F))
    rounded(NSRect(x: 458, y: 221, width: 112, height: 119), 18, color(0x56C7B1))
    rounded(NSRect(x: 364, y: 190, width: 302, height: 38), 19, color(0x88E5CC))

    NSGraphicsContext.saveGraphicsState()
    let screenShadow = NSShadow()
    screenShadow.shadowColor = color(0x00111C, alpha: 0.42)
    screenShadow.shadowBlurRadius = 38
    screenShadow.shadowOffset = NSSize(width: 0, height: -16)
    screenShadow.set()
    rounded(NSRect(x: 235, y: 309, width: 620, height: 400), 49, color(0x8AE9D4))
    NSGraphicsContext.restoreGraphicsState()
    let screen = NSBezierPath(roundedRect: NSRect(x: 251, y: 325, width: 588, height: 368), xRadius: 34, yRadius: 34)
    NSGradient(starting: color(0x28757B), ending: color(0x163B48))!.draw(in: screen, angle: -65)

    // Subtle window structure remains legible at large Dock sizes.
    rounded(NSRect(x: 282, y: 627, width: 190, height: 16), 8, color(0x93E9D2, alpha: 0.56))
    rounded(NSRect(x: 282, y: 594, width: 116, height: 12), 6, color(0x93E9D2, alpha: 0.25))
    rounded(NSRect(x: 282, y: 363, width: 161, height: 153), 18, color(0x79DCC5, alpha: 0.10))

    NSGraphicsContext.saveGraphicsState()
    let cursorShadow = NSShadow()
    cursorShadow.shadowColor = color(0x061D26, alpha: 0.48)
    cursorShadow.shadowBlurRadius = 15
    cursorShadow.shadowOffset = NSSize(width: 0, height: -7)
    cursorShadow.set()
    let cursor = NSBezierPath()
    cursor.move(to: NSPoint(x: 505, y: 620))
    cursor.line(to: NSPoint(x: 505, y: 413))
    cursor.line(to: NSPoint(x: 557, y: 464))
    cursor.line(to: NSPoint(x: 604, y: 374))
    cursor.line(to: NSPoint(x: 654, y: 401))
    cursor.line(to: NSPoint(x: 607, y: 490))
    cursor.line(to: NSPoint(x: 681, y: 490))
    cursor.close()
    color(0xF0FFF9).setFill()
    cursor.fill()
    NSGraphicsContext.restoreGraphicsState()
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels,
            pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: pixels * 4, bitsPerPixel: 32),
            let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Cannot create icon bitmap") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        let transform = NSAffineTransform()
        transform.scale(by: CGFloat(pixels) / 1024)
        transform.concat()
        drawIcon()
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let path = iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode icon") }
        try png.write(to: path)
    }
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["--convert", "icns", "--output", output.path, iconset.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    fputs("iconutil could not package the iconset. Run this script locally with normal macOS application access.\n", stderr)
    exit(process.terminationStatus)
}
print(output.path)
