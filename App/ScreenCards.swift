// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import CoreGraphics

enum ScreenCardKind { case computer, browser }

/// A local selection control. Preview images stay in memory; selecting this
/// control never synthesizes input for the remote desktop.
final class ScreenCardView: NSControl {
    static let preferredWidth: CGFloat = 244
    let screenIdentifier: String
    let kind: ScreenCardKind
    var onSelect: (() -> Void)?
    var onEdit: (() -> Void)?
    var onRemove: (() -> Void)?
    var onDisconnect: (() -> Void)?
    private(set) var isSelected = false
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let preview = NSImageView()
    private let placeholder = NSTextField(labelWithString: "No preview yet")
    private let previewBackground = NSView()

    init(identifier: String, title: String, kind: ScreenCardKind) {
        screenIdentifier = identifier; self.kind = kind
        super.init(frame: .zero)
        self.identifier = NSUserInterfaceItemIdentifier("screenCard." + identifier)
        wantsLayer = true; focusRingType = .exterior
        setAccessibilityElement(true); setAccessibilityRole(.button)
        titleLabel.font = .systemFont(ofSize:13,weight:.semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        statusLabel.font = .systemFont(ofSize:11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        let symbol = kind == .computer ? "desktopcomputer" : "globe"
        let icon = NSImageView(image:NSImage(systemSymbolName:symbol,accessibilityDescription:nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant:16),icon.heightAnchor.constraint(equalToConstant:16)])
        let header = NSStackView(views:[icon,titleLabel]); header.spacing = 6; header.alignment = .centerY
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.imageAlignment = .alignCenter
        preview.identifier = NSUserInterfaceItemIdentifier("screenCardPreview." + identifier)
        previewBackground.wantsLayer = true
        previewBackground.layer?.backgroundColor = NSColor(calibratedWhite:0.07,alpha:1).cgColor
        previewBackground.layer?.cornerRadius = 6
        previewBackground.layer?.masksToBounds = true
        placeholder.font = .systemFont(ofSize:11)
        placeholder.textColor = NSColor(calibratedWhite:0.68,alpha:1)
        if kind == .browser { placeholder.stringValue = "Saved web page" }
        for child in [preview,placeholder] { child.translatesAutoresizingMaskIntoConstraints=false; previewBackground.addSubview(child) }
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo:previewBackground.leadingAnchor),preview.trailingAnchor.constraint(equalTo:previewBackground.trailingAnchor),
            preview.topAnchor.constraint(equalTo:previewBackground.topAnchor),preview.bottomAnchor.constraint(equalTo:previewBackground.bottomAnchor),
            placeholder.centerXAnchor.constraint(equalTo:previewBackground.centerXAnchor),placeholder.centerYAnchor.constraint(equalTo:previewBackground.centerYAnchor)
        ])
        for child in [header,previewBackground,statusLabel] { child.translatesAutoresizingMaskIntoConstraints=false; addSubview(child) }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo:leadingAnchor,constant:8),header.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-8),
            header.topAnchor.constraint(equalTo:topAnchor,constant:8),header.heightAnchor.constraint(equalToConstant:18),
            previewBackground.leadingAnchor.constraint(equalTo:leadingAnchor,constant:8),previewBackground.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-8),
            previewBackground.topAnchor.constraint(equalTo:header.bottomAnchor,constant:6),
            previewBackground.heightAnchor.constraint(equalTo:previewBackground.widthAnchor,multiplier:9.0/16.0),
            statusLabel.leadingAnchor.constraint(equalTo:leadingAnchor,constant:8),statusLabel.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-8),
            statusLabel.topAnchor.constraint(equalTo:previewBackground.bottomAnchor,constant:6),statusLabel.heightAnchor.constraint(equalToConstant:14),
            statusLabel.bottomAnchor.constraint(equalTo:bottomAnchor,constant:-8)
        ])
        for child in [titleLabel,statusLabel,preview,placeholder,icon] { child.setAccessibilityElement(false) }
        update(title:title,status:kind == .computer ? "Saved computer" : "Saved page",image:nil,selected:false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isEnabled }
    override var wantsUpdateLayer: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width:Self.preferredWidth,height:8+18+6+(Self.preferredWidth-16)*9/16+6+14+8)
    }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.cornerRadius = 10
            let base = NSColor.controlBackgroundColor
            layer?.backgroundColor = (isSelected ? (base.blended(withFraction:0.13,of:.controlAccentColor) ?? base) : base).cgColor
            layer?.borderColor = (isSelected ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
            layer?.borderWidth = isSelected ? 2 : 1
        }
    }
    func update(title: String, status: String, image: NSImage?, selected: Bool) {
        precondition(Thread.isMainThread,"Screen cards must be updated on the main thread")
        titleLabel.stringValue = title; titleLabel.toolTip = title
        statusLabel.stringValue = status; statusLabel.toolTip = status
        preview.image = image; placeholder.isHidden = image != nil
        isSelected = selected
        setAccessibilityLabel(title + (kind == .computer ? ", computer" : ", web page"))
        setAccessibilityValue((selected ? "Selected. " : "") + status)
        setAccessibilityHelp("Select this screen. Control-click for available actions.")
        needsDisplay = true
    }
    /// Child labels/images are decorative; the whole card is one click target.
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        onSelect?()
    }
    override func keyDown(with event: NSEvent) {
        if [UInt16(36),76,49].contains(event.keyCode) {
            if !event.isARepeat && event.modifierFlags.intersection([.command,.control,.option]).isEmpty { _=accessibilityPerformPress() }
        }
        else { super.keyDown(with:event) }
    }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled,let select=onSelect else { return false }
        select();return true
    }
    override func resetCursorRects() { if isEnabled { addCursorRect(bounds,cursor:.pointingHand) } }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect:bounds.insetBy(dx:1,dy:1),xRadius:10,yRadius:10).fill() }
    override func menu(for event: NSEvent) -> NSMenu? {
        let result=NSMenu(title:titleLabel.stringValue); result.autoenablesItems=false
        for (title,action,available) in [
            (kind == .computer ? "Rename…" : "Edit…",#selector(editCard),onEdit != nil),
            ("Disconnect",#selector(disconnectCard),onDisconnect != nil),
            ("Remove",#selector(removeCard),onRemove != nil)
        ] where available {
            let item=result.addItem(withTitle:title,action:action,keyEquivalent:"");item.target=self;item.isEnabled=isEnabled
        }
        return result.items.isEmpty ? nil : result
    }
    @objc private func editCard() { if isEnabled { onEdit?() } }
    @objc private func disconnectCard() { if isEnabled { onDisconnect?() } }
    @objc private func removeCard() { if isEnabled { onRemove?() } }
}

/// An immutable, owned thumbnail. Alpha is ignored, matching the viewer's
/// opaque BGRX framebuffer; cgImage uses little-endian B,G,R,X channel order.
struct ScreenPreview {
    let data: Data
    let cgImage: CGImage
    let width: Int
    let height: Int
    let sampledAt: TimeInterval
    var bytesPerRow: Int { width*4 }
}

/// Safe on the connection worker: no AppKit calls, source-pointer retention,
/// full-resolution snapshots, persistence, or timers. One sampler per screen.
final class ScreenPreviewSampler {
    private let lock=NSLock()
    private let maxWidth: Int
    private let maxHeight: Int
    private let minimumInterval: TimeInterval
    private var lastSample: TimeInterval?

    init(maxWidth: Int=480,maxHeight: Int=270,minimumInterval: TimeInterval=2) {
        self.maxWidth=max(1,min(480,maxWidth));self.maxHeight=max(1,min(270,maxHeight))
        self.minimumInterval=minimumInterval.isFinite ? max(2,minimumInterval) : 2
    }
    func reset() { lock.lock();lastSample=nil;lock.unlock() }

    func sample(_ bytes: UnsafePointer<UInt8>,width: Int,height: Int,stride: Int,
                force: Bool=false,now: TimeInterval=ProcessInfo.processInfo.systemUptime) -> ScreenPreview? {
        guard width > 0,height > 0,width <= 16384,height <= 16384,
              width*height <= (256*1024*1024)/4,stride >= width*4,stride <= Int.max/height,
              now.isFinite,now >= 0 else { return nil }
        lock.lock();defer { lock.unlock() }
        if !force,let last=lastSample,now-last < minimumInterval { return nil }
        let scale=min(1,min(Double(maxWidth)/Double(width),Double(maxHeight)/Double(height)))
        let outputWidth=min(maxWidth,max(1,Int((Double(width)*scale).rounded())))
        let outputHeight=min(maxHeight,max(1,Int((Double(height)*scale).rounded())))
        var output=Data(count:outputWidth*outputHeight*4)
        output.withUnsafeMutableBytes { destination in
            let target=destination.baseAddress!.assumingMemoryBound(to:UInt8.self)
            for y in 0..<outputHeight {
                let sourceY=min(height-1,((y*2+1)*height)/(outputHeight*2))
                for x in 0..<outputWidth {
                    let sourceX=min(width-1,((x*2+1)*width)/(outputWidth*2))
                    let source=bytes.advanced(by:sourceY*stride+sourceX*4),offset=(y*outputWidth+x)*4
                    target[offset]=source[0];target[offset+1]=source[1];target[offset+2]=source[2];target[offset+3]=source[3]
                }
            }
        }
        guard let provider=CGDataProvider(data:output as CFData),
              let image=CGImage(width:outputWidth,height:outputHeight,bitsPerComponent:8,bitsPerPixel:32,
                  bytesPerRow:outputWidth*4,space:CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo:CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue:CGImageAlphaInfo.noneSkipFirst.rawValue)),
                  provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent) else { return nil }
        lastSample=now
        return ScreenPreview(data:output,cgImage:image,width:outputWidth,height:outputHeight,sampledAt:now)
    }
}
