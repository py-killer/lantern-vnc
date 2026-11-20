// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import MetalKit

private final class DesktopSurface: NSView {
    weak var desktop: MetalDesktop?
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        desktop?.layoutSurface(bounds)
    }
}

/// Metal always renders the visible viewport, never a scroll-sized document.
/// One shared geometry model drives the image, scrollbars and remote input.
final class MetalDesktop: MTKView, MTKViewDelegate {
    var onKey: ((UInt32, Bool) -> Void)?
    var onPointer: ((Int32, Int32, Int32) -> Void)?
    var onFocus: (() -> Void)?
    var onViewportChanged: (() -> Void)?
    var mapCommandToControl = true { didSet { if oldValue != mapCommandToControl { releaseKeys() } } }
    var viewOnly = false { didSet { if viewOnly { releaseKeys() } } }
    var panMode = false {
        didSet { if oldValue != panMode { releaseKeys(); dragPoint = nil; invalidateCursorRects(); onViewportChanged?() } }
    }
    var zoomMode: DesktopZoomMode {
        get { viewport.zoomMode }
        set { setZoomMode(newValue) }
    }
    var fitToWindow: Bool {
        get { if case .fit = zoomMode { return true }; return false }
        set { zoomMode = newValue ? .fit : .scale(1) }
    }
    var remoteSize: NSSize { viewport.remoteSize }
    var currentViewport: DesktopViewport { viewport }
    var displayScale: Double { Double(viewport.displayScale) }
    var canPan: Bool { viewport.canPan }
    var framesReceived: Int {
        lock.lock(); defer { lock.unlock() }
        return receivedFrameCount
    }
    private var viewport = DesktopViewport()
    private weak var surface: DesktopSurface?
    private let horizontal = NSScroller(frame:NSRect(x:0,y:0,width:200,height:12))
    private let vertical = NSScroller(frame:NSRect(x:0,y:0,width:12,height:200))
    private var layingOut = false
    private var dragPoint: CGPoint?
    private var commandQueue: MTLCommandQueue!
    private var pipeline: MTLRenderPipelineState!
    private var linearSampler: MTLSamplerState!
    private var nearestSampler: MTLSamplerState!
    private let lock = NSLock()
    private var pendingFrame: (Data, Int, Int, Int)?
    private var receivedFrameCount = 0
    private var displayNotificationQueued = false
    private final class TextureSlot {
        var texture: MTLTexture?
        let available = DispatchSemaphore(value: 1)
    }
    private var slots = (0..<3).map { _ in TextureSlot() }
    private var displayedSlot: TextureSlot?
    private var redrawAfterGPU = false
    private var pressed: [UInt16: UInt32] = [:]
    private var pointerMask: Int32 = 0
    private var lastPointer = (Int32(0), Int32(0))
    private var tracking: NSTrackingArea?
    private var wheelX: CGFloat = 0, wheelY: CGFloat = 0

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    init(renderer: Void = ()) throws {
        guard let gpu = MTLCreateSystemDefaultDevice() else { throw NSError(domain: "Metal", code: 1, userInfo: [NSLocalizedDescriptionKey: "Metal is unavailable on this Mac."]) }
        super.init(frame: .zero, device: gpu)
        commandQueue = gpu.makeCommandQueue()
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0.035, green: 0.043, blue: 0.058, alpha: 1)
        framebufferOnly = true
        autoResizeDrawable = true
        preferredFramesPerSecond = 60
        isPaused = true
        enableSetNeedsDisplay = true
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct VOut { float4 position [[position]]; float2 uv; };
        vertex VOut desktopVertex(uint id [[vertex_id]], constant float4 *v [[buffer(0)]]) {
            VOut o; o.position=float4(v[id].xy,0,1); o.uv=v[id].zw; return o;
        }
        fragment float4 desktopFragment(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
            return float4(tex.sample(s,in.uv).rgb,1.0);
        }
        """
        let library = try gpu.makeLibrary(source: source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "desktopVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "desktopFragment")
        descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
        pipeline = try gpu.makeRenderPipelineState(descriptor: descriptor)
        let sampling = MTLSamplerDescriptor()
        sampling.minFilter = .linear; sampling.magFilter = .linear
        linearSampler = gpu.makeSamplerState(descriptor: sampling)
        sampling.minFilter = .nearest; sampling.magFilter = .nearest
        nearestSampler = gpu.makeSamplerState(descriptor: sampling)
        for scroller in [horizontal, vertical] {
            scroller.controlSize = .small
            scroller.scrollerStyle = .legacy
            scroller.target = self
            scroller.action = #selector(scrollbarMoved(_:))
        }
        horizontal.identifier = NSUserInterfaceItemIdentifier("desktopHorizontalScroll")
        vertical.identifier = NSUserInterfaceItemIdentifier("desktopVerticalScroll")
        horizontal.setAccessibilityLabel("Pan remote desktop horizontally")
        vertical.setAccessibilityLabel("Pan remote desktop vertically")
        delegate = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func attach(to host: NSView) {
        surface?.removeFromSuperview()
        let container = DesktopSurface()
        container.desktop = self
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.045, alpha: 1).cgColor
        container.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(container)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            container.topAnchor.constraint(equalTo: host.topAnchor),
            container.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
        surface = container
        container.addSubview(self)
        container.addSubview(horizontal)
        container.addSubview(vertical)
        updateCanvas()
    }

    fileprivate func layoutSurface(_ rectangle: CGRect) {
        guard !layingOut else { return }
        layingOut = true
        defer { layingOut = false }
        let backing = window?.backingScaleFactor ?? 2
        let thickness = NSScroller.scrollerWidth(for: .small, scrollerStyle: .legacy)
        var available = rectangle.size
        var showHorizontal = false, showVertical = false
        // A vertical scrollbar can make the horizontal one necessary and vice versa.
        for _ in 0..<3 {
            var candidate = viewport
            candidate.setViewportSize(available, backingScale: backing)
            showHorizontal = candidate.maxPan.x > 0.01
            showVertical = candidate.maxPan.y > 0.01
            let next = CGSize(width: max(0,rectangle.width-(showVertical ? thickness : 0)),
                              height: max(0,rectangle.height-(showHorizontal ? thickness : 0)))
            if next == available { break }
            available = next
        }
        viewport.setViewportSize(available, backingScale: backing)
        let nextFrame = CGRect(origin: .zero,size:available)
        if frame != nextFrame { frame = nextFrame }
        horizontal.isHidden = !showHorizontal
        vertical.isHidden = !showVertical
        horizontal.frame = CGRect(x:0,y:available.height,width:available.width,height:thickness)
        vertical.frame = CGRect(x:available.width,y:0,width:thickness,height:available.height)
        updateScrollbars()
        needsDisplay = true
        onViewportChanged?()
    }
    func updateCanvas() {
        if let surface = surface { layoutSurface(surface.bounds) }
        else { viewport.setViewportSize(bounds.size, backingScale:window?.backingScaleFactor ?? 2); needsDisplay = true }
    }
    func setZoomMode(_ mode: DesktopZoomMode, anchor: CGPoint? = nil) {
        let remoteAnchor = anchor.flatMap { viewport.remotePoint(at:$0) }
        viewport.setZoomMode(mode, anchor:anchor)
        updateCanvas()
        // When zooming introduces scrollbars, preserve the pinch position even
        // though the drawable viewport loses the scrollbar's width or height.
        if let anchor = anchor, let remoteAnchor = remoteAnchor {
            viewport.setPan(CGPoint(x:remoteAnchor.x*viewport.pointScale-anchor.x,
                                    y:remoteAnchor.y*viewport.pointScale-anchor.y))
            updateScrollbars(); needsDisplay = true; onViewportChanged?()
        }
    }
    func panBy(dx: CGFloat, dy: CGFloat) {
        viewport.panBy(dx:dx,dy:dy)
        updateScrollbars(); needsDisplay = true; onViewportChanged?()
    }
    func setScrollFraction(x: Double? = nil, y: Double? = nil) {
        viewport.setScrollFraction(x:x,y:y)
        updateScrollbars(); needsDisplay = true; onViewportChanged?()
    }
    private func updateScrollbars() {
        let maximum = viewport.maxPan
        horizontal.doubleValue = maximum.x > 0 ? Double(viewport.pan.x/maximum.x) : 0
        vertical.doubleValue = maximum.y > 0 ? Double(viewport.pan.y/maximum.y) : 0
        horizontal.knobProportion = viewport.imageSize.width > 0 ? min(1,viewport.viewportSize.width/viewport.imageSize.width) : 1
        vertical.knobProportion = viewport.imageSize.height > 0 ? min(1,viewport.viewportSize.height/viewport.imageSize.height) : 1
    }
    @objc private func scrollbarMoved(_ sender: NSScroller) {
        let horizontalAxis = sender === horizontal
        let page = horizontalAxis ? viewport.viewportSize.width : viewport.viewportSize.height
        let delta: CGFloat
        switch sender.hitPart {
        case .decrementLine: delta = -40
        case .incrementLine: delta = 40
        case .decrementPage: delta = -page*0.9
        case .incrementPage: delta = page*0.9
        default:
            setScrollFraction(x: horizontalAxis ? sender.doubleValue : nil,
                              y: horizontalAxis ? nil : sender.doubleValue)
            return
        }
        panBy(dx:horizontalAxis ? delta : 0,dy:horizontalAxis ? 0 : delta)
    }

    func receive(_ bytes: UnsafePointer<UInt8>, width: Int, height: Int, stride: Int) {
        guard width > 0, height > 0, stride == width*4, height <= 16384, width <= 16384 else { return }
        let snapshot = Data(bytes:bytes,count:stride*height)
        lock.lock()
        receivedFrameCount += 1
        pendingFrame = (snapshot,width,height,receivedFrameCount)
        let notify = !displayNotificationQueued
        displayNotificationQueued = true
        lock.unlock()
        guard notify else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            self.displayNotificationQueued = false
            let incoming = self.pendingFrame
            self.lock.unlock()
            guard let incoming = incoming else { return }
            self.adoptFrameSize(width:incoming.1,height:incoming.2)
            self.needsDisplay = true
        }
    }
    private func adoptFrameSize(width: Int, height: Int) {
        let size = CGSize(width:width,height:height)
        if viewport.remoteSize != size { viewport.setRemoteSize(size); updateCanvas() }
    }
    func clear() {
        releaseKeys()
        lock.lock(); pendingFrame = nil; receivedFrameCount = 0; lock.unlock()
        viewport.setRemoteSize(.zero)
        slots = (0..<3).map { _ in TextureSlot() }
        displayedSlot = nil
        redrawAfterGPU = false
        dragPoint = nil
        updateCanvas()
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Never change the view frame from this callback or after acquiring a drawable.
        needsDisplay = true
    }
    func draw(in view: MTKView) {
        lock.lock(); let incoming = pendingFrame; lock.unlock()
        if let incoming = incoming,
           viewport.remoteSize != CGSize(width:incoming.1,height:incoming.2) {
            adoptFrameSize(width:incoming.1,height:incoming.2)
            DispatchQueue.main.async { [weak self] in self?.needsDisplay = true }
            return
        }
        var selected: TextureSlot?
        if incoming != nil {
            selected = slots.first { $0.available.wait(timeout:.now()) == .success }
            if selected == nil { redrawAfterGPU = true; return }
        } else if let current = displayedSlot {
            guard current.available.wait(timeout:.now()) == .success else { redrawAfterGPU = true; return }
            selected = current
        }
        guard let drawable = currentDrawable, let pass = currentRenderPassDescriptor,
              let command = commandQueue.makeCommandBuffer() else { selected?.available.signal(); return }
        if let (bytes,width,height,sequence) = incoming, let selected = selected {
            if selected.texture?.width != width || selected.texture?.height != height {
                let description = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:width,height:height,mipmapped:false)
                description.storageMode = .shared; description.usage = .shaderRead
                selected.texture = device?.makeTexture(descriptor:description)
            }
            guard let texture = selected.texture else { selected.available.signal(); return }
            bytes.withUnsafeBytes { source in
                if let base = source.baseAddress { texture.replace(region:MTLRegionMake2D(0,0,width,height),mipmapLevel:0,withBytes:base,bytesPerRow:width*4) }
            }
            lock.lock()
            if pendingFrame?.3 == sequence { pendingFrame = nil }
            lock.unlock()
            displayedSlot = selected
        }
        guard let encoder = command.makeRenderCommandEncoder(descriptor:pass) else { selected?.available.signal(); return }
        if let texture = selected?.texture, bounds.width > 0, bounds.height > 0 {
            let image = viewport.imageRect
            let left = Float(image.minX/bounds.width*2-1), right = Float(image.maxX/bounds.width*2-1)
            let top = Float(1-image.minY/bounds.height*2), bottom = Float(1-image.maxY/bounds.height*2)
            let vertices = [SIMD4<Float>(left,top,0,0),SIMD4<Float>(left,bottom,0,1),SIMD4<Float>(right,top,1,0),SIMD4<Float>(right,bottom,1,1)]
            encoder.setRenderPipelineState(pipeline)
            vertices.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!,length:$0.count,index:0) }
            encoder.setFragmentTexture(texture,index:0)
            let integerZoom = abs(viewport.displayScale-viewport.displayScale.rounded()) < 0.000001
            encoder.setFragmentSamplerState(integerZoom ? nearestSampler : linearSampler,index:0)
            encoder.drawPrimitives(type:.triangleStrip,vertexStart:0,vertexCount:4)
        }
        encoder.endEncoding()
        command.addCompletedHandler { [weak self] _ in
            selected?.available.signal()
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.lock.lock(); let pending = self.pendingFrame != nil; self.lock.unlock()
                if pending || self.redrawAfterGPU { self.redrawAfterGPU = false; self.needsDisplay = true }
            }
        }
        command.present(drawable); command.commit()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); window?.acceptsMouseMovedEvents = true; updateCanvas()
    }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); updateCanvas() }
    private func invalidateCursorRects() { window?.invalidateCursorRects(for:self) }
    override func resetCursorRects() { addCursorRect(bounds,cursor:panMode ? .openHand : .arrow) }
    override func updateTrackingAreas() {
        if let tracking = tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect:.zero,options:[.activeInKeyWindow,.mouseMoved,.inVisibleRect,.cursorUpdate],owner:self)
        addTrackingArea(tracking!); super.updateTrackingAreas()
    }
    override func cursorUpdate(with event: NSEvent) { (panMode ? NSCursor.openHand : NSCursor.arrow).set() }
    override func becomeFirstResponder() -> Bool { onFocus?(); return true }
    override func resignFirstResponder() -> Bool { releaseKeys(); dragPoint = nil; return true }
    private func position(_ event: NSEvent) -> (Int32,Int32)? {
        guard let p = viewport.remotePoint(at:convert(event.locationInWindow,from:nil),clamp:pointerMask != 0) else { return nil }
        return (Int32(p.x),Int32(p.y))
    }
    private func pointer(_ event: NSEvent, button: Int32 = 0, down: Bool? = nil) {
        guard !panMode,!viewOnly,let p = position(event) else { return }
        if down == true { window?.makeFirstResponder(self) }
        if let down = down { if down { pointerMask |= button } else { pointerMask &= ~button } }
        lastPointer = p; onPointer?(p.0,p.1,pointerMask)
    }
    override func mouseMoved(with event: NSEvent) { pointer(event) }
    override func mouseDragged(with event: NSEvent) {
        if let start = dragPoint {
            let next = convert(event.locationInWindow,from:nil)
            panBy(dx:start.x-next.x,dy:start.y-next.y); dragPoint = next
        } else { pointer(event) }
    }
    override func rightMouseDragged(with event: NSEvent) { pointer(event) }
    override func otherMouseDragged(with event: NSEvent) { pointer(event) }
    override func mouseDown(with event: NSEvent) {
        if panMode {
            window?.makeFirstResponder(self); dragPoint = convert(event.locationInWindow,from:nil); NSCursor.closedHand.set()
        } else { pointer(event,button:1,down:true) }
    }
    override func mouseUp(with event: NSEvent) {
        if dragPoint != nil { dragPoint = nil; NSCursor.openHand.set() }
        else { pointer(event,button:1,down:false) }
    }
    override func rightMouseDown(with event: NSEvent) { pointer(event,button:4,down:true) }
    override func rightMouseUp(with event: NSEvent) { pointer(event,button:4,down:false) }
    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 { pointer(event,button:2,down:true) }
        else if event.buttonNumber == 3 { pointer(event,button:128,down:true) }
    }
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { pointer(event,button:2,down:false) }
        else if event.buttonNumber == 3 { pointer(event,button:128,down:false) }
    }
    override func magnify(with event: NSEvent) {
        let value = max(0.1,min(4,displayScale*Double(1+event.magnification)))
        setZoomMode(.scale(value),anchor:convert(event.locationInWindow,from:nil))
    }
    override func scrollWheel(with event: NSEvent) {
        if panMode {
            let step: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 40
            panBy(dx:-event.scrollingDeltaX*step,dy:-event.scrollingDeltaY*step)
            return
        }
        guard !viewOnly,let p = position(event) else { return }
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 0.12 : 1
        wheelY += event.scrollingDeltaY*scale; wheelX += event.scrollingDeltaX*scale
        wheelY = max(-12,min(12,wheelY)); wheelX = max(-12,min(12,wheelX)); lastPointer = p
        func emit(_ mask: Int32) { onPointer?(p.0,p.1,pointerMask|mask); onPointer?(p.0,p.1,pointerMask) }
        var count = 0
        while abs(wheelY) >= 1 && count < 12 { emit(wheelY > 0 ? 8 : 16); wheelY += wheelY > 0 ? -1 : 1; count += 1 }
        count = 0
        while abs(wheelX) >= 1 && count < 12 { emit(wheelX > 0 ? 32 : 64); wheelX += wheelX > 0 ? -1 : 1; count += 1 }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains([.control,.command]), [24,27,29,1,3].contains(event.keyCode) { return super.performKeyEquivalent(with:event) }
        if panMode { return super.performKeyEquivalent(with:event) }
        guard window?.firstResponder === self, !viewOnly else { return super.performKeyEquivalent(with: event) }
        if event.modifierFlags.contains(.command), ![12,13,40].contains(event.keyCode), !(event.keyCode == 3 && event.modifierFlags.contains(.control)) {
            keyDown(with: event); return true
        }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if panMode {
            switch event.keyCode {
            case 123: panBy(dx:-40,dy:0)
            case 124: panBy(dx:40,dy:0)
            case 125: panBy(dx:0,dy:40)
            case 126: panBy(dx:0,dy:-40)
            case 53: panMode = false
            default: break
            }
            return
        }
        guard !viewOnly else { return }
        if let sym = Self.keySym(event) {
            if let previous = pressed[event.keyCode], previous != sym { onKey?(previous, false) }
            pressed[event.keyCode] = sym
            onKey?(sym, true)
        }
    }
    override func keyUp(with event: NSEvent) {
        if let sym = pressed.removeValue(forKey: event.keyCode), !pressed.values.contains(sym) { onKey?(sym,false) }
    }
    override func flagsChanged(with event: NSEvent) {
        guard !viewOnly,!panMode else { return }
        let key = event.keyCode
        let mapping: [UInt16:(NSEvent.ModifierFlags,UInt32)] = [
            56:(.shift,0xffe1),60:(.shift,0xffe2),59:(.control,0xffe3),62:(.control,0xffe4),
            58:(.option,0xffe9),61:(.option,0xffea),55:(.command,mapCommandToControl ? 0xffe3 : 0xffeb),54:(.command,mapCommandToControl ? 0xffe4 : 0xffec)
        ]
        if key == 57 { onKey?(0xffe5,true); onKey?(0xffe5,false); return }
        guard let (flag,sym) = mapping[key] else { return }
        let down = event.modifierFlags.contains(flag) && pressed[key] == nil
        if down {
            let alreadyPressed = pressed.values.contains(sym)
            pressed[key] = sym
            if !alreadyPressed { onKey?(sym, true) }
        } else {
            pressed.removeValue(forKey: key)
            if !pressed.values.contains(sym) { onKey?(sym, false) }
        }
    }
    func releaseKeys() {
        for sym in Set(pressed.values) { onKey?(sym,false) }
        pressed.removeAll()
        wheelX = 0; wheelY = 0
        if pointerMask != 0 { pointerMask = 0; onPointer?(lastPointer.0,lastPointer.1,0) }
    }
    static func keySym(_ e: NSEvent) -> UInt32? {
        let special: [UInt16:UInt32] = [
            36:0xff0d,76:0xff8d,48:0xff09,51:0xff08,117:0xffff,53:0xff1b,
            123:0xff51,124:0xff53,125:0xff54,126:0xff52,
            115:0xff50,119:0xff57,116:0xff55,121:0xff56,114:0xff63,
            122:0xffbe,120:0xffbf,99:0xffc0,118:0xffc1,96:0xffc2,97:0xffc3,
            98:0xffc4,100:0xffc5,101:0xffc6,109:0xffc7,103:0xffc8,111:0xffc9,
            105:0xffca,107:0xffcb,113:0xffcc,106:0xffcd,64:0xffce,
            79:0xffcf,80:0xffd0,90:0xffd1,
            65:0xffae,67:0xffaa,69:0xffab,75:0xffaf,78:0xffad,81:0xffbd,
            82:0xffb0,83:0xffb1,84:0xffb2,85:0xffb3,86:0xffb4,
            87:0xffb5,88:0xffb6,89:0xffb7,91:0xffb8,92:0xffb9
        ]
        if let value = special[e.keyCode] { return value }
        guard let scalar = e.charactersIgnoringModifiers?.unicodeScalars.first, scalar.value >= 32 else { return nil }
        return scalar.value <= 255 ? scalar.value : 0x01000000 | scalar.value
    }
}
