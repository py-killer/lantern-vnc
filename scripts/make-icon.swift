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
    // A luminous remote window is the lantern: warm glass, a protective teal
    // frame, and one clear control glyph. It remains legible at Dock sizes.
    NSGraphicsContext.saveGraphicsState()
    let tileShadow = NSShadow()
    tileShadow.shadowColor = color(0x00121C, alpha: 0.25)
    tileShadow.shadowBlurRadius = 26
    tileShadow.shadowOffset = NSSize(width: 0, height: -12)
    tileShadow.set()
    let tile = NSBezierPath(roundedRect: NSRect(x: 56, y: 56, width: 912, height: 912), xRadius: 205, yRadius: 205)
    NSGradient(starting: color(0x155562), ending: color(0x091E2B))!.draw(in: tile, angle: -65)
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(0x3DAA9B, alpha: 0.20), ending: color(0x3DAA9B, alpha: 0))!
        .draw(in: tile, relativeCenterPosition: NSPoint(x: -0.55, y: 0.6))
    color(0xD5FFF4, alpha: 0.06).setStroke()
    tile.lineWidth = 2
    tile.stroke()

    // A quiet second window supplies the remote-desktop cue without adding
    // another glyph. Warm glass is the lantern, rather than a literal handle.
    let rear = NSBezierPath(roundedRect: NSRect(x: 172, y: 414, width: 578, height: 352), xRadius: 55, yRadius: 55)
    NSGradient(starting: color(0x377F82), ending: color(0x1D4B57))!.draw(in: rear, angle: -90)
    let rearGlass = NSBezierPath(roundedRect: NSRect(x: 189, y: 431, width: 544, height: 318), xRadius: 39, yRadius: 39)
    NSGradient(starting: color(0x1A424E), ending: color(0x102E3C))!.draw(in: rearGlass, angle: -90)
    rounded(NSRect(x: 464, y: 231, width: 96, height: 74), 15, color(0x3CA990))

    NSGraphicsContext.saveGraphicsState()
    let bodyShadow = NSShadow()
    bodyShadow.shadowColor = color(0x00131D, alpha: 0.62)
    bodyShadow.shadowBlurRadius = 43
    bodyShadow.shadowOffset = NSSize(width: 0, height: -22)
    bodyShadow.set()
    let frame = NSBezierPath(roundedRect: NSRect(x: 226, y: 264, width: 572, height: 454), xRadius: 79, yRadius: 79)
    NSGradient(starting: color(0xC4F9DF), ending: color(0x32A997))!.draw(in: frame, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    color(0xE5FFF4, alpha: 0.52).setStroke()
    frame.lineWidth = 3
    frame.stroke()

    // Glass is clipped to the same window silhouette; no raster assets needed.
    let glass = NSBezierPath(roundedRect: NSRect(x: 254, y: 292, width: 516, height: 398), xRadius: 53, yRadius: 53)
    NSGradient(starting: color(0xFFE7A7), ending: color(0xDF8141))!.draw(in: glass, angle: -90)
    NSGradient(starting: color(0xFFF8DA, alpha: 0.92), ending: color(0xFFF8DA, alpha: 0))!
        .draw(in: glass, relativeCenterPosition: NSPoint(x: -0.12, y: 0.10))
    NSGraphicsContext.saveGraphicsState()
    glass.addClip()
    // The top rail makes this a remote window as well as a warm lantern.
    rounded(NSRect(x: 254, y: 620, width: 516, height: 76), 0, color(0x235C60))
    rounded(NSRect(x: 254, y: 617, width: 516, height: 5), 0, color(0x0B373F, alpha: 0.60))
    for x: CGFloat in [290, 321, 352] {
        color(0xCBF2D4, alpha: x == 290 ? 0.92 : 0.46).setFill()
        NSBezierPath(ovalIn: NSRect(x: x, y: 650, width: 12, height: 12)).fill()
    }
    let reflection = NSBezierPath()
    reflection.move(to: NSPoint(x: 254, y: 620))
    reflection.line(to: NSPoint(x: 612, y: 620))
    reflection.line(to: NSPoint(x: 254, y: 380))
    reflection.close()
    color(0xFFFFFF, alpha: 0.12).setFill()
    reflection.fill()
    NSGraphicsContext.restoreGraphicsState()
    color(0x0B4A4F, alpha: 0.32).setStroke()
    glass.lineWidth = 3
    glass.stroke()

    // A single pointer is the control affordance. Its dark edge retains a
    // crisp silhouette against the lit glass at 16/32px.
    NSGraphicsContext.saveGraphicsState()
    let pointerShadow = NSShadow()
    pointerShadow.shadowColor = color(0x4F351E, alpha: 0.34)
    pointerShadow.shadowBlurRadius = 17
    pointerShadow.shadowOffset = NSSize(width: 0, height: -8)
    pointerShadow.set()
    let pointer = NSBezierPath()
    pointer.move(to: NSPoint(x: 477, y: 572))
    pointer.line(to: NSPoint(x: 477, y: 360))
    pointer.line(to: NSPoint(x: 530, y: 410))
    pointer.line(to: NSPoint(x: 575, y: 329))
    pointer.line(to: NSPoint(x: 620, y: 354))
    pointer.line(to: NSPoint(x: 575, y: 435))
    pointer.line(to: NSPoint(x: 652, y: 435))
    pointer.close()
    pointer.lineWidth = 8
    pointer.lineJoinStyle = .round
    color(0x19505A).setStroke()
    pointer.stroke()
    color(0xF0FFF4).setFill()
    pointer.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    let baseShadow = NSShadow()
    baseShadow.shadowColor = color(0x000F1C, alpha: 0.40)
    baseShadow.shadowBlurRadius = 16
    baseShadow.shadowOffset = NSSize(width: 0, height: -8)
    baseShadow.set()
    rounded(NSRect(x: 346, y: 216, width: 332, height: 40), 20, color(0x4FBCA6))
    NSGraphicsContext.restoreGraphicsState()
    rounded(NSRect(x: 362, y: 245, width: 300, height: 4), 2, color(0xCFF8DD, alpha: 0.45))
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
let master = iconset.appendingPathComponent("icon_512x512@2x.png")
let preview = project.appendingPathComponent("docs/assets/app-icon.png")
let delivery = project.deletingLastPathComponent().appendingPathComponent("outputs/Lantern-VNC-icon.png")
for target in [preview, delivery] {
    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contentsOf: master).write(to: target, options: .atomic)
}
print(output.path)
print(preview.path)
print(delivery.path)
