// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import MetalKit
import UniformTypeIdentifiers

private final class SidebarDocument: NSView {
    override var isFlipped: Bool { true }
}

private enum AppLinks {
    static var feedback: URL { configured("feedbackURL", fallback:"https://py-killer.github.io/lantern-vnc/#feedback") }
    static var support: URL { configured("supportURL", fallback:"https://py-killer.github.io/lantern-vnc/#support") }
    private static func configured(_ key: String, fallback: String) -> URL {
        if let value=UserDefaults.standard.string(forKey:key), let url=URL(string:value), url.scheme == "https" { return url }
        return URL(string:fallback)!
    }
}

final class ViewerController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private let defaults: UserDefaults
    private let devices: DeviceStore
    private let devicePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let saveDevice = NSButton(title: "Save…", target: nil, action: nil)
    private let removeDevice = NSButton(title: "Remove", target: nil, action: nil)
    private var deviceFieldTitle: NSTextField?
    private let host = NSTextField(string: "192.168.0.101")
    private let port = NSTextField(string: "5900")
    private let password = NSSecureTextField(string: "")
    private let connect = NSButton(title: "Connect", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "Ready to connect")
    private let detail = NSTextField(wrappingLabelWithString: "Enter the VNC password set on your TightVNC server.")
    private let quality = NSPopUpButton(frame: .zero, pullsDown: false)
    private let zoom = NSPopUpButton(frame: .zero, pullsDown: false)
    private let hand = NSButton(title: "Hand", target: nil, action: nil)
    private let sidebarToggle = NSButton(image:NSImage(systemSymbolName:"sidebar.left",accessibilityDescription:"Toggle connection sidebar")!,target:nil,action:nil)
    private let zoomScales: [Double] = [0.5,0.75,1,1.25,1.5,2]
    private let viewOnly = NSButton(checkboxWithTitle: "View only", target: nil, action: nil)
    private let clipboard = NSButton(checkboxWithTitle: "Share clipboard text", target: nil, action: nil)
    private let mapCommand = NSButton(checkboxWithTitle: "Map Command to Control", target: nil, action: nil)
    private let metrics = NSTextField(labelWithString: "ARM64  ·  Metal")
    private let desktop: MetalDesktop
    private let placeholder = NSStackView()
    private let placeholderTitle = NSTextField(labelWithString: "Your desktop, one connection away.")
    private let placeholderDetail = NSTextField(wrappingLabelWithString: "Connect to your TightVNC server to see and control its screen here.")
    private let progress = NSProgressIndicator()
    private var session: VNCSession?
    private var connected = false
    private var clipboardCount = NSPasteboard.general.changeCount
    private var timer: Timer?
    private var remoteName = "Remote desktop"
    private var lastFrames = 0
    private var connectionSize = NSSize.zero
    private var sidebar: NSView!
    private var sidebarWidth: NSLayoutConstraint!
    private var sidebarHidden = false
    private var sidebarHiddenBeforeFullScreen = false
    private var sessionControls: [NSControl] = []
    private var baseFields: [NSControl] = []
    private var showFrameRate: Bool { defaults.bool(forKey: "showFrameRate") }
    var isSidebarVisible: Bool { !sidebarHidden }
    var isHandActive: Bool { desktop.panMode }
    var canMoveView: Bool { connected && desktop.canPan }

    init(viewer: Void = (), showWindow: Bool = true, preferences: UserDefaults = .standard) throws {
        defaults=preferences
        devices=DeviceStore(defaults:preferences)
        desktop = try MetalDesktop(renderer: ())
        guard desktop.device != nil else { throw NSError(domain: "LanternVNC", code: 1, userInfo: [NSLocalizedDescriptionKey: "This Mac could not create a Metal device."]) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760), styleMask: [.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Lantern VNC"
        window.subtitle = "Native remote desktop"
        window.minSize = NSSize(width: 860, height: 540)
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        if showWindow { window.setFrameAutosaveName("LanternMainWindow") }
        super.init(window: window)
        window.delegate = self
        buildUI()
        configureActions()
        restoreSettings()
        if showWindow {
            window.center()
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(sidebarHidden ? desktop : password)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        NotificationCenter.default.addObserver(self, selector: #selector(focusChanged), name: NSApplication.didBecomeActiveNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        timer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        session?.stop()
    }

    private func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let l = NSTextField(labelWithString: text); l.font = .systemFont(ofSize: size, weight: weight); l.textColor = color; return l
    }
    private func field(_ name: String, control: NSView) -> NSStackView {
        let l = label(name, weight: .medium)
        let stack = NSStackView(views: [l,control]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 7
        control.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        if control is NSTextField { control.heightAnchor.constraint(equalToConstant: 30).isActive = true }
        return stack
    }
    private func buildUI() {
        guard let content = window?.contentView else { return }
        let root = NSView(); root.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: content.leadingAnchor),root.trailingAnchor.constraint(equalTo: content.trailingAnchor),root.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor),root.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        let side = NSVisualEffectView(); side.material = .sidebar; side.blendingMode = .behindWindow; side.translatesAutoresizingMaskIntoConstraints = false
        side.wantsLayer=true; side.layer?.masksToBounds=true
        sidebar = side; root.addSubview(side)
        sidebarWidth = side.widthAnchor.constraint(equalToConstant: 288)
        NSLayoutConstraint.activate([side.leadingAnchor.constraint(equalTo: root.leadingAnchor),side.topAnchor.constraint(equalTo: root.topAnchor),side.bottomAnchor.constraint(equalTo: root.bottomAnchor),sidebarWidth])
        let brandIcon = NSImageView(image: NSImage(systemSymbolName: "rectangle.connected.to.line.below", accessibilityDescription: nil)!)
        brandIcon.contentTintColor = .systemTeal; brandIcon.symbolConfiguration = .init(pointSize: 29, weight: .medium)
        let brand = NSStackView(views: [brandIcon,label("Lantern",size:25,weight:.semibold)]); brand.spacing = 12
        let subtitle = label("LOCAL NETWORK VIEWER",size:11,weight:.semibold,color:.secondaryLabelColor)
        let header = NSStackView(views:[brand,subtitle]); header.orientation = .vertical; header.alignment = .leading; header.spacing = 10
        let title = label("Connection",size:16,weight:.semibold)
        devicePicker.font = .systemFont(ofSize: 13)
        devicePicker.identifier = NSUserInterfaceItemIdentifier("savedDevicePicker")
        devicePicker.toolTip = "Choose one of your three saved devices. Passwords are never saved."
        let deviceField = field("Saved devices", control: devicePicker)
        deviceFieldTitle = deviceField.arrangedSubviews.first as? NSTextField
        for button in [saveDevice, removeDevice] { button.bezelStyle = .rounded; button.controlSize = .small }
        saveDevice.toolTip = "Save the current server and port, or rename this saved device"
        removeDevice.toolTip = "Remove this device from the saved list"
        let deviceButtons = NSStackView(views: [saveDevice, removeDevice]); deviceButtons.spacing = 8
        host.placeholderString = "IP address or hostname"; port.placeholderString = "5900"; password.placeholderString = "VNC password"
        for f in [host,port,password] { f.font = .systemFont(ofSize:14); f.focusRingType = .default; f.lineBreakMode = .byTruncatingTail }
        host.identifier = NSUserInterfaceItemIdentifier("serverHost"); port.identifier = NSUserInterfaceItemIdentifier("serverPort"); password.identifier = NSUserInterfaceItemIdentifier("serverPassword")
        host.delegate = self; port.delegate = self
        let hostField = field("Server",control:host)
        let passwordField = field("Password",control:password)
        let portField = field("Port",control:port)
        quality.addItems(withTitles:["Balanced · fast LAN","Lossless · sharp text","Fast · lower bandwidth"])
        quality.font = .systemFont(ofSize:13)
        let profileField = field("Picture quality",control:quality)
        connect.bezelStyle = .rounded; connect.controlSize = .large; connect.font = .systemFont(ofSize:14,weight:.semibold); connect.keyEquivalent = "\r"; connect.contentTintColor = .white; connect.bezelColor = .systemTeal
        connect.identifier = NSUserInterfaceItemIdentifier("connectButton")
        for b in [viewOnly,clipboard,mapCommand] { b.font = .systemFont(ofSize:13) }
        let help = NSTextField(wrappingLabelWithString: "The password stays in memory for this session. No account or subscription needed.")
        help.font = .systemFont(ofSize:12); help.textColor = .secondaryLabelColor
        let bottom = label("Apple Silicon  ·  Open source",size:11,color:.secondaryLabelColor)
        let fields = NSStackView(views:[header,deviceField,deviceButtons,title,hostField,portField,passwordField,connect,profileField,viewOnly,clipboard,mapCommand,help,bottom])
        fields.orientation = .vertical; fields.alignment = .leading; fields.spacing = 14; fields.translatesAutoresizingMaskIntoConstraints = false
        let sidebarScroll = NSScrollView(); sidebarScroll.translatesAutoresizingMaskIntoConstraints = false
        sidebarScroll.drawsBackground = false; sidebarScroll.hasVerticalScroller = true; sidebarScroll.autohidesScrollers = true
        let document = SidebarDocument(); document.translatesAutoresizingMaskIntoConstraints = false
        sidebarScroll.documentView = document; side.addSubview(sidebarScroll); document.addSubview(fields)
        NSLayoutConstraint.activate([sidebarScroll.leadingAnchor.constraint(equalTo:side.leadingAnchor),sidebarScroll.widthAnchor.constraint(equalToConstant:288),sidebarScroll.topAnchor.constraint(equalTo:side.topAnchor),sidebarScroll.bottomAnchor.constraint(equalTo:side.bottomAnchor),document.widthAnchor.constraint(equalTo:sidebarScroll.contentView.widthAnchor),fields.leadingAnchor.constraint(equalTo:document.leadingAnchor,constant:22),fields.trailingAnchor.constraint(equalTo:document.trailingAnchor,constant:-22),fields.topAnchor.constraint(equalTo:document.topAnchor,constant:24),fields.bottomAnchor.constraint(equalTo:document.bottomAnchor,constant:-24)])
        for child in [deviceField,hostField,portField,passwordField,profileField,connect,help] { child.widthAnchor.constraint(equalTo:fields.widthAnchor).isActive = true }
        baseFields = [host,port,password,quality]

        let main = NSView(); main.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(main)
        NSLayoutConstraint.activate([main.leadingAnchor.constraint(equalTo:side.trailingAnchor),main.trailingAnchor.constraint(equalTo:root.trailingAnchor),main.topAnchor.constraint(equalTo:root.topAnchor),main.bottomAnchor.constraint(equalTo:root.bottomAnchor)])
        let top = NSView(); top.translatesAutoresizingMaskIntoConstraints = false; main.addSubview(top)
        NSLayoutConstraint.activate([top.leadingAnchor.constraint(equalTo:main.leadingAnchor),top.trailingAnchor.constraint(equalTo:main.trailingAnchor),top.topAnchor.constraint(equalTo:main.topAnchor),top.heightAnchor.constraint(equalToConstant:50)])
        status.font = .systemFont(ofSize:13,weight:.medium)
        status.lineBreakMode = .byTruncatingMiddle
        status.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        progress.style = .spinning; progress.controlSize = .small; progress.isDisplayedWhenStopped = false
        let stateStack = NSStackView(views:[progress,status]); stateStack.spacing=8; stateStack.translatesAutoresizingMaskIntoConstraints=false; top.addSubview(stateStack)
        zoom.addItems(withTitles:["Auto (Readable)","Fit to Window","50%","75%","100%","125%","150%","200%"])
        zoom.controlSize = .small; zoom.font = .systemFont(ofSize:12)
        zoom.target=self; zoom.action=#selector(scaleChanged)
        zoom.identifier=NSUserInterfaceItemIdentifier("desktopZoom")
        zoom.setAccessibilityLabel("Desktop zoom")
        zoom.toolTip="Auto keeps large desktops readable. Fit shows the whole screen. 100% uses one remote pixel per physical screen pixel."
        zoom.widthAnchor.constraint(equalToConstant:154).isActive=true
        hand.setButtonType(.toggle); hand.bezelStyle = .texturedRounded; hand.controlSize = .small
        hand.image=NSImage(systemSymbolName:"hand.draw",accessibilityDescription:nil)
        hand.imagePosition = .imageLeading; hand.target=self; hand.action=#selector(toggleHand)
        hand.identifier=NSUserInterfaceItemIdentifier("panViewButton"); hand.isEnabled=false
        hand.toolTip="Move view: drag, scroll, or use arrow keys. Turn off Hand or press Esc to control the remote computer."
        sidebarToggle.bezelStyle = .texturedRounded; sidebarToggle.controlSize = .small
        sidebarToggle.setButtonType(.toggle)
        sidebarToggle.target=self; sidebarToggle.action=#selector(toggleSidebar)
        sidebarToggle.identifier=NSUserInterfaceItemIdentifier("sidebarToggleButton")
        sidebarToggle.toolTip="Hide connection sidebar (Control–Command–S)"
        let full = NSButton(image:NSImage(systemSymbolName:"arrow.up.left.and.arrow.down.right",accessibilityDescription:"Full screen")!,target:self,action:#selector(fullScreen))
        full.bezelStyle = .texturedRounded; full.toolTip="Full screen (Control–Command–F)"
        let tools = NSStackView(views:[sidebarToggle,zoom,hand,full]); tools.spacing=8; tools.translatesAutoresizingMaskIntoConstraints=false; top.addSubview(tools)
        tools.setContentCompressionResistancePriority(.required,for:.horizontal)
        NSLayoutConstraint.activate([stateStack.leadingAnchor.constraint(equalTo:top.leadingAnchor,constant:18),stateStack.centerYAnchor.constraint(equalTo:top.centerYAnchor),tools.trailingAnchor.constraint(equalTo:top.trailingAnchor,constant:-16),tools.centerYAnchor.constraint(equalTo:top.centerYAnchor),stateStack.trailingAnchor.constraint(lessThanOrEqualTo:tools.leadingAnchor,constant:-16)])
        let viewport = NSView(); viewport.wantsLayer=true; viewport.layer?.backgroundColor=NSColor(calibratedWhite:0.055,alpha:1).cgColor; viewport.translatesAutoresizingMaskIntoConstraints=false; main.addSubview(viewport)
        NSLayoutConstraint.activate([viewport.topAnchor.constraint(equalTo:top.bottomAnchor),viewport.leadingAnchor.constraint(equalTo:main.leadingAnchor),viewport.trailingAnchor.constraint(equalTo:main.trailingAnchor),viewport.bottomAnchor.constraint(equalTo:main.bottomAnchor,constant:-55)])
        desktop.attach(to:viewport)
        let screen = NSImageView(image:NSImage(systemSymbolName:"desktopcomputer",accessibilityDescription:nil)!); screen.contentTintColor=NSColor(calibratedWhite:0.48,alpha:1); screen.symbolConfiguration = .init(pointSize:62,weight:.ultraLight)
        placeholderTitle.font = .systemFont(ofSize:23,weight:.medium); placeholderTitle.textColor=NSColor(calibratedWhite:0.91,alpha:1); placeholderTitle.alignment = .center
        placeholderDetail.font = .systemFont(ofSize:14); placeholderDetail.textColor=NSColor(calibratedWhite:0.55,alpha:1); placeholderDetail.alignment = .center
        placeholder.setViews([screen,placeholderTitle,placeholderDetail],in:.center); placeholder.orientation = .vertical; placeholder.alignment = .centerX; placeholder.spacing=20; placeholder.translatesAutoresizingMaskIntoConstraints=false; viewport.addSubview(placeholder)
        NSLayoutConstraint.activate([placeholder.centerXAnchor.constraint(equalTo:viewport.centerXAnchor),placeholder.centerYAnchor.constraint(equalTo:viewport.centerYAnchor),placeholder.leadingAnchor.constraint(greaterThanOrEqualTo:viewport.leadingAnchor,constant:32),placeholder.trailingAnchor.constraint(lessThanOrEqualTo:viewport.trailingAnchor,constant:-32),placeholderDetail.widthAnchor.constraint(lessThanOrEqualToConstant:390)])
        let cad=NSButton(title:"Ctrl–Alt–Del",target:self,action:#selector(sendCAD)); cad.bezelStyle = .rounded
        let send=NSButton(title:"Clipboard",target:self,action:#selector(sendClipboard)); send.bezelStyle = .rounded; send.toolTip="Send local clipboard text to the remote computer"
        let refresh=NSButton(image:NSImage(systemSymbolName:"arrow.clockwise",accessibilityDescription:"Refresh screen")!,target:self,action:#selector(refreshScreen)); refresh.bezelStyle = .rounded; refresh.toolTip="Request full screen update"
        metrics.font = .monospacedSystemFont(ofSize:12,weight:.regular); metrics.textColor = .secondaryLabelColor
        metrics.lineBreakMode = .byTruncatingMiddle
        metrics.toolTip = "Remote resolution and scale in physical screen pixels. Use the scrollbars or Hand to navigate a larger desktop. Enable frame rate in the Session menu."
        let buttons=NSStackView(views:[cad,send,refresh]); buttons.spacing=10; buttons.translatesAutoresizingMaskIntoConstraints=false; main.addSubview(buttons)
        metrics.translatesAutoresizingMaskIntoConstraints=false; main.addSubview(metrics)
        NSLayoutConstraint.activate([buttons.leadingAnchor.constraint(equalTo:main.leadingAnchor,constant:16),buttons.bottomAnchor.constraint(equalTo:main.bottomAnchor,constant:-13),metrics.trailingAnchor.constraint(equalTo:main.trailingAnchor,constant:-18),metrics.centerYAnchor.constraint(equalTo:buttons.centerYAnchor),metrics.leadingAnchor.constraint(greaterThanOrEqualTo:buttons.trailingAnchor,constant:12)])
        sessionControls=[cad,send,refresh]; sessionControls.forEach{$0.isEnabled=false}
        detail.font = .systemFont(ofSize:12); detail.textColor = .secondaryLabelColor
    }
    private func configureActions() {
        connect.target=self; connect.action=#selector(toggleConnection)
        devicePicker.target=self; devicePicker.action=#selector(deviceSelected)
        saveDevice.target=self; saveDevice.action=#selector(saveCurrentDevice)
        removeDevice.target=self; removeDevice.action=#selector(removeCurrentDevice)
        viewOnly.target=self; viewOnly.action=#selector(optionsChanged)
        clipboard.target=self; clipboard.action=#selector(optionsChanged)
        mapCommand.target=self; mapCommand.action=#selector(optionsChanged)
        desktop.onKey = { [weak self] key, down in self?.session?.key(key,down:down) }
        desktop.onPointer = { [weak self] x,y,mask in self?.session?.pointer(x:x,y:y,mask:mask) }
        desktop.onFocus = { [weak self] in self?.syncClipboard() }
        desktop.onViewportChanged = { [weak self] in self?.updateViewportUI() }
        devicePicker.nextKeyView = saveDevice; saveDevice.nextKeyView = removeDevice
        removeDevice.nextKeyView = host; host.nextKeyView = port; port.nextKeyView = password
        password.nextKeyView = quality; quality.nextKeyView = viewOnly; viewOnly.nextKeyView = clipboard
        clipboard.nextKeyView = mapCommand; mapCommand.nextKeyView = connect; connect.nextKeyView = devicePicker
    }
    private func restoreSettings() {
        host.stringValue = defaults.string(forKey:"server") ?? "192.168.0.101"
        port.stringValue = defaults.string(forKey:"port") ?? "5900"
        clipboard.state = defaults.bool(forKey:"clipboard") ? .on : .off
        mapCommand.state = defaults.object(forKey:"mapCommand") == nil || defaults.bool(forKey:"mapCommand") ? .on : .off
        quality.selectItem(at:max(0,min(2,defaults.integer(forKey:"quality"))))
        desktop.mapCommandToControl = mapCommand.state == .on
        refreshDevicePicker()
        zoom.selectItem(at:0); desktop.zoomMode = .automatic
        setSidebarHidden(defaults.bool(forKey:"sidebarHidden"),persist:false)
    }
    private var currentDevice: SavedDevice? {
        guard let number = UInt16(port.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)) else { return nil }
        return devices.find(host: host.stringValue, port: number)
    }
    private func refreshDevicePicker() {
        let current = currentDevice
        deviceFieldTitle?.stringValue = "Saved devices · \(devices.devices.count) of \(DeviceStore.maximumDevices)"
        devicePicker.removeAllItems()
        if current == nil {
            devicePicker.addItem(withTitle: "Unsaved connection")
            devicePicker.lastItem?.representedObject = "__unsaved__"
        }
        for device in devices.devices {
            devicePicker.addItem(withTitle: "\(device.name) · \(device.host):\(device.port)")
            devicePicker.lastItem?.representedObject = device.id
            devicePicker.lastItem?.toolTip = "\(device.host):\(device.port)"
        }
        if devices.devices.count < DeviceStore.maximumDevices {
            if !devices.devices.isEmpty { devicePicker.menu?.addItem(.separator()) }
            devicePicker.addItem(withTitle: "Add device…")
            devicePicker.lastItem?.representedObject = "__add__"
        }
        if let id = current?.id, let item = devicePicker.itemArray.first(where: { $0.representedObject as? String == id }) {
            devicePicker.select(item)
        } else { devicePicker.selectItem(at: 0) }
        updateDeviceControls()
    }
    private func updateDeviceControls() {
        let available = session == nil
        devicePicker.isEnabled = available
        saveDevice.isEnabled = available && !host.stringValue.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
        removeDevice.isEnabled = available && currentDevice != nil
    }
    func controlTextDidChange(_ notification: Notification) { refreshDevicePicker() }
    @objc private func deviceSelected() {
        guard session == nil, let id = devicePicker.selectedItem?.representedObject as? String else { return }
        if id == "__add__" {
            host.stringValue = ""; port.stringValue = "5900"; password.stringValue = ""
            status.stringValue = "New connection"
            refreshDevicePicker(); window?.makeFirstResponder(host)
        } else if let device = devices.devices.first(where: { $0.id == id }) {
            host.stringValue = device.host; port.stringValue = String(device.port); password.stringValue = ""
            defaults.set(device.host,forKey:"server"); defaults.set(String(device.port),forKey:"port")
            status.stringValue = "Ready to connect"
            placeholderTitle.stringValue = "Your desktop, one connection away."
            placeholderDetail.stringValue = "Connect to \(device.name) to see and control its screen here."
            updateDeviceControls(); window?.makeFirstResponder(password)
        }
    }
    @objc private func saveCurrentDevice() {
        guard session == nil else { return }
        let address = host.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !address.isEmpty, !address.contains("/"), let number = UInt16(port.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)), number > 0 else {
            showError("Enter a valid server address and port before saving this device."); return
        }
        guard currentDevice != nil || devices.devices.count < DeviceStore.maximumDevices else {
            let alert = NSAlert(); alert.messageText = "Three devices saved"
            alert.informativeText = "Remove a saved device before adding another. You can still connect using the Server and Port fields."
            alert.beginSheetModal(for:window!); return
        }
        let alert = NSAlert(); alert.messageText = currentDevice == nil ? "Save device" : "Name this device"
        alert.informativeText = "\(address):\(number)\nOnly the name, server, and port are saved."
        let name = NSTextField(string: currentDevice?.name ?? address)
        name.frame = NSRect(x:0,y:0,width:290,height:26); name.placeholderString = "Device name"
        alert.accessoryView = name; alert.addButton(withTitle:"Save"); alert.addButton(withTitle:"Cancel")
        alert.beginSheetModal(for:window!) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self = self, self.session == nil else { return }
            if self.devices.save(name:name.stringValue,host:address,port:number) != nil {
                self.refreshDevicePicker(); self.status.stringValue = "Device saved"
            }
        }
        alert.window.makeFirstResponder(name); name.selectText(nil)
    }
    @objc private func removeCurrentDevice() {
        guard session == nil, let device = currentDevice else { return }
        devices.remove(id:device.id); refreshDevicePicker(); status.stringValue = "Device removed from saved list"
    }
    @objc func toggleConnection() {
        if let session = session {
            desktop.releaseKeys(); connect.isEnabled=false
            status.stringValue = connected ? "Disconnecting…" : "Canceling…"
            session.stop(); return
        }
        let address = host.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !address.isEmpty, !address.contains("/"), let number = UInt16(port.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)), number > 0 else {
            showError("Enter a valid server address and port (1–65535)."); return
        }
        host.stringValue = address; port.stringValue = String(number)
        zoom.selectItem(at:0); desktop.zoomMode = .automatic; desktop.panMode=false; lastFrames = 0
        defaults.set(address,forKey:"server"); defaults.set(port.stringValue,forKey:"port"); defaults.set(quality.indexOfSelectedItem,forKey:"quality")
        let next = VNCSession(); session=next
        next.onConnected = { [weak self,weak next] name,width,height in
            guard let self=self, self.session === next else { return }
            self.connected=true; self.remoteName=name
            self.connectionSize = NSSize(width:width,height:height)
            let name = self.devices.find(host:address,port:number)?.name ?? address
            _ = self.devices.save(name:name,host:address,port:number)
            self.refreshDevicePicker()
            self.status.stringValue=name == address ? address : "\(name) · \(address)"
            self.status.toolTip="Connected to \(address):\(number)"
            self.window?.subtitle="\(address):\(number)"
            self.placeholder.isHidden=true; self.progress.stopAnimation(nil)
            self.connect.title="Disconnect"; self.connect.isEnabled=true; self.connect.keyEquivalent=""
            self.sessionControls.forEach{$0.isEnabled=true}
            if self.viewOnly.state == .on { self.sessionControls[0].isEnabled=false; self.sessionControls[1].isEnabled=false }
            self.window?.makeFirstResponder(self.desktop)
            self.updateViewportUI()
            self.clipboardCount = -1; self.syncClipboard()
        }
        next.onFrame = { [weak desktop] bytes,width,height,stride in desktop?.receive(bytes,width:width,height:height,stride:stride) }
        next.onClipboard = { [weak self] text in
            guard let self=self,self.clipboard.state == .on else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text,forType:.string); self.clipboardCount=NSPasteboard.general.changeCount
        }
        next.onDisconnected = { [weak self,weak next] reason,intentional in
            guard let self=self,self.session === next else { return }
            self.connected=false; self.session=nil; self.progress.stopAnimation(nil)
            self.connect.title="Connect"; self.connect.isEnabled=true; self.connect.keyEquivalent="\r"
            self.baseFields.forEach{$0.isEnabled=true}; self.sessionControls.forEach{$0.isEnabled=false}
            self.updateDeviceControls()
            self.desktop.clear(); self.placeholder.isHidden=false
            self.updateViewportUI()
            self.setSidebarHidden(false,persist:false)
            self.status.stringValue=intentional ? "Disconnected" : "Connection failed"
            self.placeholderTitle.stringValue=intentional ? "Ready when you are." : "Couldn’t connect."
            self.placeholderDetail.stringValue=intentional ? "Connect again to resume your remote session." : reason
            self.metrics.stringValue="ARM64  ·  Metal"
            self.connectionSize = .zero
            self.window?.makeFirstResponder(self.password)
        }
        baseFields.forEach{$0.isEnabled=false}; updateDeviceControls(); connect.title="Cancel"; connect.keyEquivalent="\u{1b}"; progress.startAnimation(nil)
        status.stringValue="Connecting to \(address)…"
        placeholderTitle.stringValue="Connecting…"; placeholderDetail.stringValue="Opening a direct connection to \(address):\(number)."; placeholder.isHidden=false
        let value = password.stringValue
        password.stringValue=""
        if !next.start(host:address,port:number,password:value,viewOnly:viewOnly.state == .on,quality:[8,-1,5][quality.indexOfSelectedItem]) {
            session=nil; baseFields.forEach{$0.isEnabled=true}; updateDeviceControls()
            connect.title="Connect"; connect.keyEquivalent="\r"; progress.stopAnimation(nil)
            status.stringValue="Connection failed"; placeholderTitle.stringValue="Couldn’t connect."
            placeholderDetail.stringValue="Could not start the connection worker. Try connecting again."
            window?.makeFirstResponder(password)
            showError("Could not start the connection worker.")
        }
    }
    private func showError(_ text: String) {
        let alert=NSAlert(); alert.messageText="Connection settings"; alert.informativeText=text; alert.beginSheetModal(for:window!)
    }
    @objc private func optionsChanged() {
        desktop.releaseKeys()
        desktop.viewOnly=viewOnly.state == .on; desktop.mapCommandToControl=mapCommand.state == .on
        session?.viewOnly(viewOnly.state == .on)
        if connected { sessionControls[0].isEnabled=viewOnly.state != .on; sessionControls[1].isEnabled=viewOnly.state != .on }
        defaults.set(clipboard.state == .on,forKey:"clipboard"); defaults.set(mapCommand.state == .on,forKey:"mapCommand")
        if clipboard.state == .on { clipboardCount = -1; syncClipboard() }
    }
    @objc private func scaleChanged() {
        switch zoom.indexOfSelectedItem {
        case 0: setZoom(.automatic)
        case 1: setZoom(.fit)
        case 2..<8: setZoom(.scale(zoomScales[zoom.indexOfSelectedItem - 2]))
        default: break
        }
    }
    private func setZoom(_ mode: DesktopZoomMode) {
        desktop.releaseKeys(); desktop.zoomMode=mode
        desktop.updateCanvas(); updateViewportUI()
        if connected { window?.makeFirstResponder(desktop) }
    }
    @objc func automaticZoom() { setZoom(.automatic) }
    @objc func fitZoom() { setZoom(.fit) }
    @objc func actualSize() { setZoom(.scale(1)) }
    @objc func zoomIn() {
        let current=desktop.displayScale
        let steps: [Double]=[0.1,0.25] + zoomScales + [3,4]
        setZoom(.scale(steps.first(where:{$0 > current + 0.005}) ?? 4))
    }
    @objc func zoomOut() {
        let current=desktop.displayScale
        let steps: [Double]=[0.1,0.25] + zoomScales + [3,4]
        setZoom(.scale(steps.reversed().first(where:{$0 < current - 0.005}) ?? 0.1))
    }
    @objc func toggleHand() {
        guard connected,desktop.canPan else { hand.state = .off; return }
        desktop.releaseKeys(); desktop.panMode.toggle(); updateViewportUI()
        window?.makeFirstResponder(desktop)
    }
    private func updateViewportUI() {
        hand.isEnabled=connected && desktop.canPan
        if !desktop.canPan && desktop.panMode { desktop.panMode=false }
        hand.state=desktop.panMode ? .on : .off
        switch desktop.zoomMode {
        case .automatic:
            if zoom.numberOfItems > 8 { zoom.removeItem(at:8) }; zoom.selectItem(at:0)
        case .fit:
            if zoom.numberOfItems > 8 { zoom.removeItem(at:8) }; zoom.selectItem(at:1)
        case .scale(let scale):
            if let index=zoomScales.firstIndex(where:{abs($0-scale) < 0.005}) {
                if zoom.numberOfItems > 8 { zoom.removeItem(at:8) }; zoom.selectItem(at:index+2)
            } else {
                let title="\(Int((scale * 100).rounded()))% (Custom)"
                if zoom.numberOfItems == 8 { zoom.addItem(withTitle:title) }
                else { zoom.item(at:8)?.title=title }
                zoom.selectItem(at:8)
            }
        }
        updateMetrics()
    }
    @objc func toggleSidebar() {
        setSidebarHidden(!sidebarHidden,persist:true)
        window?.makeFirstResponder(connected || sidebarHidden ? desktop : password)
    }
    private func setSidebarHidden(_ hidden: Bool,persist: Bool) {
        sidebarHidden=hidden; sidebar.isHidden=hidden; sidebarWidth.constant=hidden ? 0 : 288
        sidebarToggle.state=hidden ? .off : .on
        sidebarToggle.toolTip="\(hidden ? "Show" : "Hide") connection sidebar (Control–Command–S)"
        if persist {
            defaults.set(hidden,forKey:"sidebarHidden")
            if window?.styleMask.contains(.fullScreen) == true { sidebarHiddenBeforeFullScreen=hidden }
        }
        window?.contentView?.layoutSubtreeIfNeeded()
        desktop.updateCanvas(); updateViewportUI()
    }
    @objc func fullScreen() { window?.toggleFullScreen(nil) }
    @objc func sendCAD() { if viewOnly.state != .on { desktop.releaseKeys(); session?.controlAltDelete(); window?.makeFirstResponder(desktop) } }
    @objc func sendClipboard() {
        guard connected, viewOnly.state != .on, let text=NSPasteboard.general.string(forType:.string) else { return }
        session?.clipboard(text); clipboardCount=NSPasteboard.general.changeCount; window?.makeFirstResponder(desktop)
    }
    @objc func refreshScreen() { session?.refresh(); window?.makeFirstResponder(desktop) }
    @objc private func focusChanged() { if window?.firstResponder === desktop { syncClipboard() } }
    private func syncClipboard() {
        guard connected, clipboard.state == .on, viewOnly.state != .on, NSApp.isActive, window?.isKeyWindow == true, clipboardCount != NSPasteboard.general.changeCount else { return }
        if let text=NSPasteboard.general.string(forType:.string) { session?.clipboard(text) }
        clipboardCount=NSPasteboard.general.changeCount
    }
    private func tick() {
        guard connected else { return }
        let current=desktop.framesReceived
        let fps=max(0,current-lastFrames); lastFrames=current
        updateMetrics(fps:fps)
        if window?.firstResponder === desktop { syncClipboard() }
    }
    private func updateMetrics(fps: Int? = nil) {
        guard connected else { return }
        let size = desktop.remoteSize.width > 0 ? desktop.remoteSize : connectionSize
        guard size.width > 0, size.height > 0 else { return }
        let percentage=max(1,Int((desktop.displayScale * 100).rounded()))
        let scaling: String
        switch desktop.zoomMode {
        case .automatic: scaling="Auto \(percentage)%"
        case .fit: scaling="Fit \(percentage)%"
        case .scale: scaling="\(percentage)%"
        }
        let navigation=desktop.panMode ? " · Hand" : ""
        let rate = showFrameRate && fps != nil ? " · \(fps!) fps" : ""
        metrics.stringValue = "\(Int(size.width))×\(Int(size.height)) · \(scaling)\(navigation)\(rate) · Metal"
    }
    @objc func toggleFrameRate(_ sender: NSMenuItem) {
        defaults.set(!showFrameRate,forKey:"showFrameRate")
        sender.state = showFrameRate ? .on : .off
        updateMetrics()
    }
    func windowDidResignKey(_ notification: Notification) { desktop.releaseKeys() }
    func windowDidResize(_ notification: Notification) { desktop.updateCanvas(); updateMetrics() }
    func windowDidEnterFullScreen(_ notification: Notification) { sidebarHiddenBeforeFullScreen=sidebarHidden; setSidebarHidden(true,persist:false) }
    func windowDidExitFullScreen(_ notification: Notification) { setSidebarHidden(sidebarHiddenBeforeFullScreen,persist:false) }
    func windowWillClose(_ notification: Notification) { desktop.releaseKeys(); session?.stop(); NSApp.terminate(nil) }
    func stop() { desktop.releaseKeys(); session?.stop() }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var controller: ViewerController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        do { controller=try ViewerController(); NSApp.activate(ignoringOtherApps:true) }
        catch { let alert=NSAlert(error:error); alert.runModal(); NSApp.terminate(nil) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { controller?.stop() }
    private func buildMenu() {
        let menu=NSMenu()
        let app=NSMenuItem(); menu.addItem(app); let appMenu=NSMenu(); app.submenu=appMenu
        appMenu.addItem(withTitle:"About Lantern VNC",action:#selector(about),keyEquivalent:"").target=self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle:"Hide Lantern VNC",action:#selector(NSApplication.hide(_:)),keyEquivalent:"h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle:"Quit Lantern VNC",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        let sessionItem=NSMenuItem(); sessionItem.title="Session"; menu.addItem(sessionItem); let session=NSMenu(title:"Session"); sessionItem.submenu=session
        let connect=session.addItem(withTitle:"Connect / Disconnect",action:#selector(connection),keyEquivalent:"k"); connect.target=self
        session.addItem(withTitle:"Send Ctrl–Alt–Del",action:#selector(cad),keyEquivalent:"").target=self
        session.addItem(withTitle:"Send clipboard text",action:#selector(paste),keyEquivalent:"").target=self
        session.addItem(withTitle:"Refresh screen",action:#selector(refresh),keyEquivalent:"").target=self
        session.addItem(.separator())
        let rate=session.addItem(withTitle:"Show Frame Rate",action:#selector(frameRate(_:)),keyEquivalent:"")
        rate.target=self; rate.state=UserDefaults.standard.bool(forKey:"showFrameRate") ? .on : .off
        let viewItem=NSMenuItem(); viewItem.title="View"; menu.addItem(viewItem)
        let view=NSMenu(title:"View"); viewItem.submenu=view
        view.addItem(withTitle:"Auto (Readable)",action:#selector(automaticZoom),keyEquivalent:"").target=self
        view.addItem(withTitle:"Fit to Window",action:#selector(fitZoom),keyEquivalent:"").target=self
        let actual=view.addItem(withTitle:"Actual Size (100%)",action:#selector(actualSize),keyEquivalent:"0")
        actual.target=self; actual.keyEquivalentModifierMask=[.control,.command]
        view.addItem(.separator())
        let larger=view.addItem(withTitle:"Zoom In",action:#selector(zoomIn),keyEquivalent:"+")
        larger.target=self; larger.keyEquivalentModifierMask=[.control,.command]
        let equal=view.addItem(withTitle:"Zoom In",action:#selector(zoomIn),keyEquivalent:"=")
        equal.target=self; equal.keyEquivalentModifierMask=[.control,.command]
        equal.isHidden=true; equal.allowsKeyEquivalentWhenHidden=true
        let smaller=view.addItem(withTitle:"Zoom Out",action:#selector(zoomOut),keyEquivalent:"-")
        smaller.target=self; smaller.keyEquivalentModifierMask=[.control,.command]
        view.addItem(.separator())
        view.addItem(withTitle:"Move View with Hand",action:#selector(handTool),keyEquivalent:"").target=self
        let sidebarItem=view.addItem(withTitle:"Hide Connection Sidebar",action:#selector(sidebar),keyEquivalent:"s")
        sidebarItem.target=self; sidebarItem.keyEquivalentModifierMask=[.control,.command]
        let windowItem=NSMenuItem(); windowItem.title="Window"; menu.addItem(windowItem); let window=NSMenu(title:"Window"); windowItem.submenu=window
        window.addItem(withTitle:"Minimize",action:#selector(NSWindow.miniaturize(_:)),keyEquivalent:"m")
        let full=window.addItem(withTitle:"Enter Full Screen",action:#selector(fullscreen),keyEquivalent:"f"); full.keyEquivalentModifierMask=[.control,.command]; full.target=self
        let helpItem=NSMenuItem(); helpItem.title="Help"; menu.addItem(helpItem)
        let help=NSMenu(title:"Help"); helpItem.submenu=help
        help.addItem(withTitle:"Send Feedback…",action:#selector(feedback),keyEquivalent:"").target=self
        help.addItem(withTitle:"Save Feedback…",action:#selector(saveFeedback),keyEquivalent:"").target=self
        help.addItem(withTitle:"Support Lantern VNC…",action:#selector(support),keyEquivalent:"").target=self
        NSApp.mainMenu=menu; NSApp.windowsMenu=window
    }
    @objc private func connection() { controller?.toggleConnection() }
    @objc private func cad() { controller?.sendCAD() }
    @objc private func paste() { controller?.sendClipboard() }
    @objc private func refresh() { controller?.refreshScreen() }
    @objc private func fullscreen() { controller?.fullScreen() }
    @objc private func automaticZoom() { controller?.automaticZoom() }
    @objc private func fitZoom() { controller?.fitZoom() }
    @objc private func actualSize() { controller?.actualSize() }
    @objc private func zoomIn() { controller?.zoomIn() }
    @objc private func zoomOut() { controller?.zoomOut() }
    @objc private func handTool() { controller?.toggleHand() }
    @objc private func sidebar() { controller?.toggleSidebar() }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(handTool) {
            menuItem.state=controller?.isHandActive == true ? .on : .off
            return controller?.canMoveView == true
        }
        if menuItem.action == #selector(sidebar) {
            menuItem.title=controller?.isSidebarVisible == true ? "Hide Connection Sidebar" : "Show Connection Sidebar"
        }
        return true
    }
    @objc private func frameRate(_ sender: NSMenuItem) { controller?.toggleFrameRate(sender) }
    @objc private func feedback() { NSWorkspace.shared.open(AppLinks.feedback) }
    @objc private func support() { NSWorkspace.shared.open(AppLinks.support) }
    @objc private func saveFeedback() {
        guard let window=controller?.window else { return }
        let alert=NSAlert(); alert.messageText="Save feedback"
        alert.informativeText="Describe what happened and what you expected. The text file includes your notes, app version, macOS version, and GPU name."
        let text=NSTextView(frame:NSRect(x:0,y:0,width:360,height:150))
        text.font = .systemFont(ofSize:13); text.isRichText=false
        text.isVerticallyResizable=true; text.isHorizontallyResizable=false
        text.textContainer?.widthTracksTextView=true
        let scroll=NSScrollView(frame:NSRect(x:0,y:0,width:360,height:150))
        scroll.borderType = .bezelBorder; scroll.hasVerticalScroller=true; scroll.documentView=text
        alert.accessoryView=scroll; alert.addButton(withTitle:"Choose Location…"); alert.addButton(withTitle:"Cancel")
        alert.beginSheetModal(for:window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self=self else { return }
            self.exportFeedback(text.string,for:window)
        }
        alert.window.makeFirstResponder(text)
    }
    private func exportFeedback(_ notes: String, for window: NSWindow) {
        let version=Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "1.0"
        let build=Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "Unknown"
        let channel=Bundle.main.object(forInfoDictionaryKey:"LanternReleaseChannel") as? String ?? "Release"
        let gpu=MTLCreateSystemDefaultDevice()?.name ?? "Unavailable"
        let report="""
        Lantern VNC feedback
        App version: \(version)
        Release channel: \(channel)
        Build: \(build)
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        GPU: \(gpu)
        Renderer: Metal

        Feedback:
        \(notes)

        """
        let panel=NSSavePanel(); panel.title="Save Lantern VNC feedback"
        panel.nameFieldStringValue="LanternVNC-feedback.txt"; panel.allowedContentTypes=[.plainText]
        panel.canCreateDirectories=true
        panel.beginSheetModal(for:window) { response in
            guard response == .OK, let url=panel.url else { return }
            do { try report.write(to:url,atomically:true,encoding:.utf8) }
            catch { NSAlert(error:error).beginSheetModal(for:window) }
        }
    }
    @objc private func about() {
        let version=Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "1.1.0"
        let channel=Bundle.main.object(forInfoDictionaryKey:"LanternReleaseChannel") as? String ?? ""
        NSApp.orderFrontStandardAboutPanel(options:[.applicationName:"Lantern VNC",.applicationVersion:"\(version) \(channel)",.credits:NSAttributedString(string:"Native Apple Silicon VNC viewer\nAppKit · Metal · LibVNCClient · libjpeg-turbo\nGPL-2.0-or-later\nThis software is based in part on the work of the Independent JPEG Group.")])
    }
}

#if !APP_UI_HARNESS
@main
struct LanternApplication {
    static func main() {
        let application=NSApplication.shared
        let appDelegate=AppDelegate()
        application.setActivationPolicy(.regular)
        application.delegate=appDelegate
        application.run()
    }
}
#endif
