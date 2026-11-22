// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import MetalKit
import UniformTypeIdentifiers
import WebKit

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
    private let remembersWindowFrame: Bool
    private let connectionPreferences: ConnectionPreferencesStore
    private var applyingConnectionPreferences=false
    private var displayedPreferencesEndpoint: String?
    private var lastObservedZoom: DesktopZoomMode = .fit
    private let devices: DeviceStore
    private let passwordStore: PasswordStorage
    private let previewInterval: TimeInterval
    private var previewIntervalMilliseconds: UInt32 { UInt32((previewInterval*1000).rounded()) }
    private let browserStore: BrowserScreenStore
    private var computers: [String: WorkspaceComputer] = [:]
    private var computerImages: [String: NSImage] = [:]
    private var computerSampleTimes: [String: TimeInterval] = [:]
    private var computerMessages: [String: String] = [:]
    private lazy var frameRouter = ScreenFrameRouter { [weak desktop] bytes,width,height,stride,dirty in
        desktop?.receive(bytes,width:width,height:height,stride:stride,dirty:dirty)
    }
    private let cards = NSStackView()
    private var computerCards: [String: ScreenCardView] = [:]
    private var browserCards: [String: ScreenCardView] = [:]
    private var cardOrder: [String] = []
    private let workspaceNotice = NSTextField(wrappingLabelWithString: "")
    private let addScreen = NSPopUpButton(frame: .zero, pullsDown: true)
    private let settingsDisclosure = NSButton(title: "Connection settings", target: nil, action: nil)
    private var settingsGroup: NSStackView!
    private var vncPane: NSView!
    private var webHost: NSView!
    private var selectedBrowserID: String?
    private var browserPanes: [String: BrowserScreenPane] = [:]
    private lazy var browserWebsiteDataStore: WKWebsiteDataStore = remembersWindowFrame ? .default() : .nonPersistent()
    private var browserImages: [String: NSImage] = [:]
    private var browserSampleTimes: [String: TimeInterval] = [:]
    private var browserAttemptTimes: [String: TimeInterval] = [:]
    private var browserUse: [String: Int] = [:]
    private var browserUseSequence = 0
    private var menuBrowserActive: Bool?
    private var browserSnapshotInFlight: [String: UUID] = [:]
    private let maximumLoadedBrowsers = 6
    private var credentialEndpoint: String?
    private var discoveryController: VNCDiscoveryController?
    private var pendingAlias: (endpoint:String,name:String)?
    private let devicePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let saveDevice = NSButton(title: "Save…", target: nil, action: nil)
    private let removeDevice = NSButton(title: "Remove", target: nil, action: nil)
    private var deviceFieldTitle: NSTextField?
    private let host = NSTextField(string: "192.168.0.101")
    private let port = NSTextField(string: "5900")
    private let password = NSSecureTextField(string: "")
    private let rememberPassword = NSButton(checkboxWithTitle:"Remember password",target:nil,action:nil)
    private let passwordHint = NSTextField(wrappingLabelWithString:"Saved securely on this Mac only when you choose to remember it.")
    private let findServers = NSButton(title:"Find…",target:nil,action:nil)
    private let connect = NSButton(title: "Connect", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "Ready to connect")
    private let latency = NSTextField(labelWithString: NetworkLatency.unavailable.title)
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
    private var networkLatency=NetworkLatency.unavailable
    private var connectionSize = NSSize.zero
    private var sidebar: NSView!
    private var sidebarWidth: NSLayoutConstraint!
    private var sidebarHidden = false
    private var sidebarHiddenBeforeFullScreen = false
    private var sessionControls: [NSControl] = []
    private var baseFields: [NSControl] = []
    private var showFrameRate: Bool { defaults.bool(forKey: "showFrameRate") }
    var isSidebarVisible: Bool { !sidebarHidden }
    var isBrowserActive: Bool { selectedBrowserID != nil }
    var isHandActive: Bool { desktop.panMode }
    var canMoveView: Bool { connected && desktop.canPan }

    init(viewer: Void = (), showWindow: Bool = true, preferences: UserDefaults = .standard, passwordStore: PasswordStorage = PasswordStore(), previewInterval: TimeInterval = 10) throws {
        defaults=preferences
        remembersWindowFrame=showWindow
        connectionPreferences=ConnectionPreferencesStore(defaults:preferences)
        devices=DeviceStore(defaults:preferences)
        self.passwordStore=passwordStore
        self.previewInterval=previewInterval.isFinite ? max(2,min(60,previewInterval)) : 10
        browserStore=BrowserScreenStore(defaults:preferences)
        desktop = try MetalDesktop(renderer: ())
        guard desktop.device != nil else { throw NSError(domain: "LanternVNC", code: 1, userInfo: [NSLocalizedDescriptionKey: "This Mac could not create a Metal device."]) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760), styleMask: [.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Lantern VNC"
        window.subtitle = "Native remote desktop"
        window.minSize = NSSize(width: 860, height: 540)
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildUI()
        configureActions()
        // Swift lazy initialization is not synchronized. Build this shared
        // routing gate on main before any background VNC worker can use it.
        _ = frameRouter
        restoreSettings()
        if showWindow {
            WindowPlacement.restoreAndRegister(window)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(sidebarHidden ? desktop : password)
            DispatchQueue.main.async { [weak self] in self?.startSavedPreviews() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        NotificationCenter.default.addObserver(self, selector: #selector(focusChanged), name: NSApplication.didBecomeActiveNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        timer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        computers.values.forEach { $0.session.stop() }
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
        let subtitle = label("YOUR SCREEN WORKSPACE",size:11,weight:.semibold,color:.secondaryLabelColor)
        let header = NSStackView(views:[brand,subtitle]); header.orientation = .vertical; header.alignment = .leading; header.spacing = 10
        let title = label("Connection",size:16,weight:.semibold)
        devicePicker.font = .systemFont(ofSize: 13)
        devicePicker.identifier = NSUserInterfaceItemIdentifier("savedDevicePicker")
        devicePicker.toolTip = "Choose one of your three saved devices. Saved passwords are kept securely and separately on this Mac."
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
        findServers.bezelStyle = .rounded; findServers.controlSize = .small
        findServers.identifier = NSUserInterfaceItemIdentifier("findServersButton")
        findServers.toolTip = "Find VNC servers on your local Wi-Fi or Ethernet network using the selected port"
        findServers.setAccessibilityLabel("Find VNC servers on this network")
        let serverRow = NSStackView(views:[host,findServers]); serverRow.spacing=7
        host.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        host.widthAnchor.constraint(greaterThanOrEqualToConstant:100).isActive=true
        host.heightAnchor.constraint(equalToConstant:30).isActive=true
        let hostField = field("Server",control:serverRow)
        let passwordField = field("Password",control:password)
        rememberPassword.font = .systemFont(ofSize:13)
        rememberPassword.identifier = NSUserInterfaceItemIdentifier("rememberPassword")
        rememberPassword.toolTip = "Save securely on this Mac after a successful connection. Uncheck to remove the saved password."
        passwordHint.font = .systemFont(ofSize:12); passwordHint.textColor = .secondaryLabelColor
        passwordHint.identifier = NSUserInterfaceItemIdentifier("passwordHint")
        let portField = field("Port",control:port)
        quality.addItems(withTitles:["Balanced · fast LAN","Lossless · sharp text","Fast · lower bandwidth","Wi-Fi · high quality"])
        quality.font = .systemFont(ofSize:13)
        quality.identifier = NSUserInterfaceItemIdentifier("pictureQuality")
        quality.target=self; quality.action=#selector(pictureQualityChanged)
        quality.toolTip="Wi-Fi requests more compression at the same JPEG quality as Balanced, using more server CPU. Lossless avoids JPEG artifacts. Changes apply to your next connection."
        let profileField = field("Picture quality",control:quality)
        connect.bezelStyle = .rounded; connect.controlSize = .large; connect.font = .systemFont(ofSize:14,weight:.semibold); connect.keyEquivalent = "\r"; connect.contentTintColor = .white; connect.bezelColor = .systemTeal
        connect.identifier = NSUserInterfaceItemIdentifier("connectButton")
        for b in [viewOnly,clipboard,mapCommand] { b.font = .systemFont(ofSize:13) }
        let help = NSTextField(wrappingLabelWithString: "No account or subscription needed. Passwords are never stored in device profiles.")
        help.font = .systemFont(ofSize:12); help.textColor = .secondaryLabelColor
        let bottom = label("Apple Silicon  ·  Open source",size:11,color:.secondaryLabelColor)
        addScreen.addItems(withTitles:["Add screen", "Computer…", "Browser window…"])
        addScreen.identifier=NSUserInterfaceItemIdentifier("addScreenButton")
        addScreen.bezelStyle = .rounded;addScreen.font = .systemFont(ofSize:13,weight:.medium)
        cards.orientation = .vertical;cards.alignment = .leading;cards.spacing=12
        cards.identifier=NSUserInterfaceItemIdentifier("screenCardList")
        settingsDisclosure.setButtonType(.toggle);settingsDisclosure.bezelStyle = .recessed
        settingsDisclosure.image=NSImage(systemSymbolName:"slider.horizontal.3",accessibilityDescription:nil)
        settingsDisclosure.imagePosition = .imageLeading;settingsDisclosure.state = .on
        settingsDisclosure.identifier=NSUserInterfaceItemIdentifier("connectionSettingsDisclosure")
        settingsGroup=NSStackView(views:[deviceField,deviceButtons,title,hostField,portField,passwordField,rememberPassword,passwordHint,connect,profileField,viewOnly,clipboard,mapCommand,help])
        settingsGroup.orientation = .vertical;settingsGroup.alignment = .leading;settingsGroup.spacing=14
        workspaceNotice.font = .systemFont(ofSize:12);workspaceNotice.textColor = .secondaryLabelColor
        workspaceNotice.isHidden=true;workspaceNotice.identifier=NSUserInterfaceItemIdentifier("workspaceNotice")
        let fields = NSStackView(views:[header,addScreen,workspaceNotice,cards,settingsDisclosure,settingsGroup,bottom])
        fields.orientation = .vertical; fields.alignment = .leading; fields.spacing = 14; fields.translatesAutoresizingMaskIntoConstraints = false
        let sidebarScroll = NSScrollView(); sidebarScroll.translatesAutoresizingMaskIntoConstraints = false
        sidebarScroll.drawsBackground = false; sidebarScroll.hasVerticalScroller = true; sidebarScroll.autohidesScrollers = true
        let document = SidebarDocument(); document.translatesAutoresizingMaskIntoConstraints = false
        sidebarScroll.documentView = document; side.addSubview(sidebarScroll); document.addSubview(fields)
        NSLayoutConstraint.activate([sidebarScroll.leadingAnchor.constraint(equalTo:side.leadingAnchor),sidebarScroll.widthAnchor.constraint(equalToConstant:288),sidebarScroll.topAnchor.constraint(equalTo:side.topAnchor),sidebarScroll.bottomAnchor.constraint(equalTo:side.bottomAnchor),document.widthAnchor.constraint(equalTo:sidebarScroll.contentView.widthAnchor),fields.leadingAnchor.constraint(equalTo:document.leadingAnchor,constant:22),fields.trailingAnchor.constraint(equalTo:document.trailingAnchor,constant:-22),fields.topAnchor.constraint(equalTo:document.topAnchor,constant:24),fields.bottomAnchor.constraint(equalTo:document.bottomAnchor,constant:-24)])
        for child in [addScreen,workspaceNotice,cards,settingsDisclosure,settingsGroup!,deviceField,hostField,portField,passwordField,passwordHint,profileField,connect,help] { child.widthAnchor.constraint(equalTo:fields.widthAnchor).isActive = true }
        baseFields = [host,port,password,quality,rememberPassword,findServers]

        let main = NSView(); main.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(main)
        vncPane=main
        NSLayoutConstraint.activate([main.leadingAnchor.constraint(equalTo:side.trailingAnchor),main.trailingAnchor.constraint(equalTo:root.trailingAnchor),main.topAnchor.constraint(equalTo:root.topAnchor),main.bottomAnchor.constraint(equalTo:root.bottomAnchor)])
        webHost=NSView();webHost.translatesAutoresizingMaskIntoConstraints=false;webHost.isHidden=true
        webHost.identifier=NSUserInterfaceItemIdentifier("browserScreenHost");root.addSubview(webHost)
        NSLayoutConstraint.activate([webHost.leadingAnchor.constraint(equalTo:side.trailingAnchor),webHost.trailingAnchor.constraint(equalTo:root.trailingAnchor),webHost.topAnchor.constraint(equalTo:root.topAnchor),webHost.bottomAnchor.constraint(equalTo:root.bottomAnchor)])
        let top = NSView(); top.translatesAutoresizingMaskIntoConstraints = false; main.addSubview(top)
        top.identifier=NSUserInterfaceItemIdentifier("viewerHeader")
        NSLayoutConstraint.activate([top.leadingAnchor.constraint(equalTo:main.leadingAnchor),top.trailingAnchor.constraint(equalTo:main.trailingAnchor),top.topAnchor.constraint(equalTo:main.topAnchor),top.heightAnchor.constraint(equalToConstant:50)])
        status.font = .systemFont(ofSize:13,weight:.medium)
        status.identifier=NSUserInterfaceItemIdentifier("connectionStatus")
        status.lineBreakMode = .byTruncatingMiddle
        status.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        latency.identifier=NSUserInterfaceItemIdentifier("networkLatency")
        latency.font = .monospacedDigitSystemFont(ofSize:11,weight:.regular)
        latency.textColor = .secondaryLabelColor
        latency.lineBreakMode = .byTruncatingTail
        latency.isHidden=true
        latency.toolTip=NetworkLatency.unavailable.toolTip
        latency.setContentCompressionResistancePriority(.required,for:.horizontal)
        progress.style = .spinning; progress.controlSize = .small; progress.isDisplayedWhenStopped = false
        let statusDetails = NSStackView(views:[status,latency]);statusDetails.orientation = .vertical
        statusDetails.alignment = .leading;statusDetails.spacing=2
        status.widthAnchor.constraint(equalTo:statusDetails.widthAnchor).isActive=true
        let stateStack = NSStackView(views:[progress,statusDetails]);stateStack.spacing=8
        stateStack.translatesAutoresizingMaskIntoConstraints=false; top.addSubview(stateStack)
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
        sidebarToggle.imagePosition = .imageLeading
        sidebarToggle.font = .systemFont(ofSize:12)
        sidebarToggle.setButtonType(.toggle)
        sidebarToggle.target=self; sidebarToggle.action=#selector(toggleSidebar)
        sidebarToggle.identifier=NSUserInterfaceItemIdentifier("sidebarToggleButton")
        sidebarToggle.toolTip="Hide connection sidebar (Control–Command–S)"
        let full = NSButton(image:NSImage(systemSymbolName:"arrow.up.left.and.arrow.down.right",accessibilityDescription:"Full screen")!,target:self,action:#selector(fullScreen))
        full.identifier=NSUserInterfaceItemIdentifier("fullscreenButton")
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
    }
    private func configureActions() {
        addScreen.target=self;addScreen.action=#selector(addScreenSelected)
        settingsDisclosure.target=self;settingsDisclosure.action=#selector(toggleConnectionSettings)
        connect.target=self; connect.action=#selector(toggleConnection)
        rememberPassword.target=self; rememberPassword.action=#selector(rememberPasswordChanged)
        findServers.target=self; findServers.action=#selector(findNetworkServers)
        devicePicker.target=self; devicePicker.action=#selector(deviceSelected)
        saveDevice.target=self; saveDevice.action=#selector(saveCurrentDevice)
        removeDevice.target=self; removeDevice.action=#selector(removeCurrentDevice)
        viewOnly.target=self; viewOnly.action=#selector(optionsChanged)
        clipboard.target=self; clipboard.action=#selector(optionsChanged)
        mapCommand.target=self; mapCommand.action=#selector(optionsChanged)
        desktop.onKey = { [weak self] key, down in
            guard let self=self,self.selectedBrowserID == nil else { return }
            self.session?.key(key,down:down)
        }
        desktop.onPointer = { [weak self] x,y,mask in
            guard let self=self,self.selectedBrowserID == nil else { return }
            self.session?.pointer(x:x,y:y,mask:mask)
        }
        desktop.onFocus = { [weak self] in self?.syncClipboard() }
        desktop.onViewportChanged = { [weak self] in
            guard let self=self else { return }
            self.updateViewportUI()
            if !self.applyingConnectionPreferences,self.lastObservedZoom != self.desktop.zoomMode {
                self.lastObservedZoom=self.desktop.zoomMode
                self.persistConnectionPreferences()
            }
        }
        devicePicker.nextKeyView = saveDevice; saveDevice.nextKeyView = removeDevice
        removeDevice.nextKeyView = host; host.nextKeyView = findServers; findServers.nextKeyView = port; port.nextKeyView = password
        password.nextKeyView = rememberPassword; rememberPassword.nextKeyView = quality; quality.nextKeyView = viewOnly; viewOnly.nextKeyView = clipboard
        clipboard.nextKeyView = mapCommand; mapCommand.nextKeyView = connect; connect.nextKeyView = devicePicker
    }
    private func restoreSettings() {
        host.stringValue = defaults.string(forKey:"server") ?? "192.168.0.101"
        port.stringValue = defaults.string(forKey:"port") ?? "5900"
        clipboard.state = defaults.bool(forKey:"clipboard") ? .on : .off
        mapCommand.state = defaults.object(forKey:"mapCommand") == nil || defaults.bool(forKey:"mapCommand") ? .on : .off
        desktop.mapCommandToControl = mapCommand.state == .on
        refreshDevicePicker()
        loadRememberedPassword()
        migrateConnectionPreferences()
        restoreConnectionPreferences()
        setSidebarHidden(defaults.bool(forKey:"sidebarHidden"),persist:false)
        refreshScreenCards()
    }
    private func migrateConnectionPreferences() {
        let marker="connectionPreferencesMigrated.v1"
        guard !defaults.bool(forKey:marker) else { return }
        if defaults.object(forKey:"quality") != nil {
            let oldQuality=defaults.integer(forKey:"quality")
            var endpoints=devices.devices.map { ($0.host,$0.port) }
            if let endpoint=endpoint { endpoints.append(endpoint) }
            for (host,port) in endpoints {
                let saved=connectionPreferences.load(host:host,port:port,legacyQuality:oldQuality)
                connectionPreferences.save(host:host,port:port,zoomMode:saved.zoomMode,qualityIndex:saved.qualityIndex)
            }
        }
        defaults.set(true,forKey:marker)
    }
    private func restoreConnectionPreferences() {
        applyingConnectionPreferences=true
        defer { applyingConnectionPreferences=false }
        let saved: ConnectionPreferences
        displayedPreferencesEndpoint=endpointIdentity
        if let (host,port)=endpoint { saved=connectionPreferences.load(host:host,port:port) }
        else { saved=ConnectionPreferences(zoomMode:.fit,qualityIndex:3) }
        quality.selectItem(at:saved.qualityIndex)
        lastObservedZoom=saved.zoomMode
        desktop.zoomMode=saved.zoomMode;desktop.updateCanvas();updateViewportUI()
    }
    private func persistConnectionPreferences() {
        guard !applyingConnectionPreferences,displayedPreferencesEndpoint == endpointIdentity,
              let (host,port)=endpoint else { return }
        connectionPreferences.save(host:host,port:port,zoomMode:desktop.zoomMode,qualityIndex:max(0,min(3,quality.indexOfSelectedItem)))
    }
    @objc private func pictureQualityChanged() {
        defaults.set(max(0,min(3,quality.indexOfSelectedItem)),forKey:"quality")
        persistConnectionPreferences()
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
        refreshScreenCards()
    }
    private func updateDeviceControls() {
        let available = session == nil
        devicePicker.isEnabled = available
        saveDevice.title=currentDevice == nil ? "Save…" : "Rename…"
        saveDevice.isEnabled = available && !host.stringValue.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
        removeDevice.isEnabled = available && currentDevice != nil
    }
    private var endpoint: (String,UInt16)? {
        let address=host.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !address.isEmpty,let number=UInt16(port.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)),number>0 else { return nil }
        return (address,number)
    }
    private var endpointIdentity: String? {
        endpoint.map { "\($0.0.lowercased().utf8.count):\($0.0.lowercased()):\($0.1)" }
    }
    private func loadRememberedPassword() {
        guard session == nil else { return }
        password.stringValue="";rememberPassword.state = .off;credentialEndpoint=endpointIdentity
        passwordHint.stringValue="Saved securely on this Mac only when you choose to remember it."
        guard let (address,number)=endpoint else { return }
        do {
            if let saved=try passwordStore.read(host:address,port:number) {
                password.stringValue=saved;rememberPassword.state = .on
                passwordHint.stringValue="Saved password ready."
            }
        } catch {
            passwordHint.stringValue="Saved password unavailable to this build. Authorization dialogs are disabled."
        }
    }
    func controlTextDidChange(_ notification: Notification) {
        if credentialEndpoint != endpointIdentity {
            password.stringValue=""; rememberPassword.state = .off; credentialEndpoint=nil; pendingAlias=nil
            passwordHint.stringValue="Saved securely on this Mac only when you choose to remember it."
        }
        refreshDevicePicker()
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        guard session == nil,credentialEndpoint != endpointIdentity else { return }
        loadRememberedPassword()
        restoreConnectionPreferences()
    }
    @objc private func rememberPasswordChanged() {
        guard let (address,number)=endpoint else { rememberPassword.state = .off; return }
        if rememberPassword.state == .on {
            passwordHint.stringValue="Will save securely after a successful connection."
        } else {
            do {
                try passwordStore.remove(host:address,port:number)
                passwordHint.stringValue="Saved password removed. You can still connect without saving."
            } catch {
                rememberPassword.state = .off
                passwordHint.stringValue="Password won’t be saved. The existing saved password couldn’t be removed."
            }
        }
    }
    private func rememberAfterConnection(host:String,port:UInt16,password:String?) {
        guard let password=password else { return }
        do {
            try passwordStore.save(host:host,port:port,password:password)
            passwordHint.stringValue="Password saved securely on this Mac."
        } catch {
            rememberPassword.state = .off
            passwordHint.stringValue="Connected, but the password was not saved: "+error.localizedDescription
        }
    }
    @objc func findNetworkServers() {
        guard session == nil,discoveryController == nil else { return }
        guard let number=UInt16(port.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)),number>0,let window=window else {
            showError("Enter the VNC server’s TCP port before searching. The usual port is 5900.");return
        }
        let picker=VNCDiscoveryController(knownAlias:{ [weak self] host,port in self?.devices.find(host:host,port:port)?.name });discoveryController=picker
        picker.onClose={ [weak self] in self?.discoveryController=nil }
        picker.present(on:window,port:number) { [weak self] server,alias in
            self?.acceptDiscoveredServer(server,alias:alias)
        }
    }
    /// Confirmation saves the selected alias immediately, without authentication.
    func acceptDiscoveredServer(_ server:DiscoveredVNCServer,alias:String?) {
        guard session == nil else { return }
        host.stringValue=server.host;port.stringValue=String(server.port)
        defaults.set(server.host,forKey:"server");defaults.set(String(server.port),forKey:"port")
        let name=alias ?? devices.find(host:server.host,port:server.port)?.name ?? "VNC computer"
        if devices.save(name:name,host:server.host,port:server.port) != nil {
            pendingAlias=nil
            status.stringValue="\(name) · saved and ready to connect"
        } else {
            pendingAlias=endpointIdentity.map { ($0,name) }
            status.stringValue="Three devices saved · this connection is not saved"
            showError("Your list already has three devices. This server is selected for a one-off connection. Remove a saved device if you want to add it to the list.")
        }
        loadRememberedPassword();restoreConnectionPreferences();refreshDevicePicker()
        window?.makeFirstResponder(password)
    }
    @objc private func deviceSelected() {
        guard session == nil, let id = devicePicker.selectedItem?.representedObject as? String else { return }
        if id == "__add__" {
            pendingAlias=nil
            host.stringValue = ""; port.stringValue = "5900"; loadRememberedPassword(); restoreConnectionPreferences()
            status.stringValue = "New connection"
            refreshDevicePicker(); window?.makeFirstResponder(host)
        } else if let device = devices.devices.first(where: { $0.id == id }) {
            pendingAlias=nil
            host.stringValue = device.host; port.stringValue = String(device.port); loadRememberedPassword(); restoreConnectionPreferences()
            defaults.set(device.host,forKey:"server"); defaults.set(String(device.port),forKey:"port")
            status.stringValue = "Ready to connect"
            status.toolTip=nil;window?.subtitle="Native remote desktop"
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
        alert.informativeText = "\(address):\(number)\nThe profile saves its name, server, and port. Remembered passwords are saved securely and separately."
        let name = NSTextField(string: pendingAlias?.name ?? currentDevice?.name ?? address)
        name.frame = NSRect(x:0,y:0,width:290,height:26); name.placeholderString = "Device name"
        alert.accessoryView = name; alert.addButton(withTitle:"Save"); alert.addButton(withTitle:"Cancel")
        alert.beginSheetModal(for:window!) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self = self, self.session == nil else { return }
            if self.devices.save(name:name.stringValue,host:address,port:number) != nil {
                self.pendingAlias=nil
                self.refreshDevicePicker(); self.status.stringValue = "Device saved"
            }
        }
        alert.window.makeFirstResponder(name); name.selectText(nil)
    }
    @objc private func removeCurrentDevice() {
        guard session == nil, let device = currentDevice else { return }
        removeComputerProfile(id:device.id)
    }
    @objc func toggleConnection() {
        guard selectedBrowserID == nil else { return }
        if let session = session {
            desktop.releaseKeys(); connect.isEnabled=false
            status.stringValue = connected ? "Disconnecting…" : "Canceling…"
            if let key=endpointIdentity { computers[key]?.phase = .closing }
            session.stop(); return
        }
        let address=host.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !address.isEmpty,!address.contains("/"),let number=UInt16(port.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)),number>0 else {
            showError("Enter a valid server address and port (1–65535).");return
        }
        host.stringValue=address;port.stringValue=String(number)
        restoreConnectionPreferences();desktop.panMode=false;lastFrames=0
        defaults.set(address,forKey:"server");defaults.set(port.stringValue,forKey:"port")
        defaults.set(quality.indexOfSelectedItem,forKey:"quality")
        let value=password.stringValue
        let shouldRemember=rememberPassword.state == .on
        password.stringValue=""
        startComputer(host:address,port:number,password:value,remember:shouldRemember,activate:true)
    }

    private func isSelected(_ computer: WorkspaceComputer) -> Bool {
        selectedBrowserID == nil && endpointIdentity == computer.key && session === computer.session
    }

    private func startComputer(host address:String,port number:UInt16,password value:String,remember:Bool,activate:Bool) {
        let key=WorkspaceComputer.key(host:address,port:number)
        if let existing=computers[key] {
            if activate { promoteComputer(existing) }
            return
        }
        let computer=WorkspaceComputer(host:address,port:number,name:devices.find(host:address,port:number)?.name ?? address,previewInterval:previewInterval)
        let next=computer.session
        computers[key]=computer;computerMessages[key]=nil
        var passwordToRemember:String?=remember ? value : nil
        if activate {
            session=next;connected=false
            frameRouter.select(computer.token) { desktop.clear() }
            baseFields.forEach{$0.isEnabled=false};updateDeviceControls()
            connect.title="Cancel";connect.isEnabled=true;connect.keyEquivalent="\u{1b}";progress.startAnimation(nil)
            status.stringValue="Connecting to \(address)…";status.toolTip=nil;window?.subtitle="\(address):\(number)"
            placeholderTitle.stringValue="Connecting…";placeholderDetail.stringValue="Opening a direct connection to \(address):\(number).";placeholder.isHidden=false
        }
        next.onConnected={ [weak self,weak computer] name,width,height in
            guard let self=self,let computer=computer,self.computers[key] === computer else { return }
            guard computer.phase != .closing else { computer.session.stop();return }
            computer.phase = .connected;computer.size=NSSize(width:width,height:height)
            let serverTitle=name.components(separatedBy:.controlCharacters).joined(separator:" ").trimmingCharacters(in:.whitespacesAndNewlines)
            let alias=self.pendingAlias?.endpoint == key ? self.pendingAlias?.name : nil
            computer.name=alias ?? self.devices.find(host:address,port:number)?.name ?? (serverTitle.isEmpty ? "VNC computer" : String(serverTitle.prefix(80)))
            _ = self.devices.save(name:computer.name,host:address,port:number)
            if let secret=passwordToRemember {
                do {
                    try self.passwordStore.save(host:address,port:number,password:secret)
                    computer.credentialNote="Password saved securely on this Mac."
                } catch {
                    computer.credentialNote="Connected, but the password was not saved: "+error.localizedDescription
                    if self.isSelected(computer) { self.rememberPassword.state = .off }
                }
            }
            passwordToRemember=nil
            if self.isSelected(computer) { self.showConnectedComputer(computer) }
            else { _=computer.session.setUpdateInterval(milliseconds:self.previewIntervalMilliseconds);computer.session.viewOnly(true) }
            self.refreshDevicePicker();self.refreshScreenCards()
        }
        next.onFrame={ [weak self,weak computer] bytes,width,height,stride,dirty in
            guard let self=self,let computer=computer else { return }
            let selected=self.frameRouter.receive(token:computer.token,bytes:bytes,width:width,height:height,stride:stride,dirty:dirty)
            if (!selected || !computer.sampler.hasSample),let preview=computer.sampler.sample(bytes,width:width,height:height,stride:stride) {
                DispatchQueue.main.async { [weak self,weak computer] in
                    guard let self=self,let computer=computer,self.computers[key] === computer else { return }
                    if self.isSelected(computer),self.computerImages[key] != nil { return }
                    let image=NSImage(cgImage:preview.cgImage,size:NSSize(width:preview.width,height:preview.height))
                    self.computerImages[key]=image;self.computerSampleTimes[key]=preview.sampledAt
                    self.refreshScreenCards()
                }
            }
        }
        next.onClipboard={ [weak self,weak computer] text in
            guard let self=self,let computer=computer,self.isSelected(computer),self.clipboard.state == .on else { return }
            NSPasteboard.general.clearContents();NSPasteboard.general.setString(text,forType:.string)
            self.clipboardCount=NSPasteboard.general.changeCount
        }
        next.onDisconnected={ [weak self,weak computer] reason,intentional in
            passwordToRemember=nil
            guard let self=self,let computer=computer,self.computers[key] === computer else { return }
            let selected=self.isSelected(computer)
            self.computers.removeValue(forKey:key)
            self.computerMessages[key]=intentional ? "Disconnected" : "Unavailable"
            if selected {
                self.session=nil;self.connected=false;self.progress.stopAnimation(nil)
                self.frameRouter.select(nil) { self.desktop.clear() }
                self.renderNetworkLatency(.unavailable,visible:false)
                self.connect.title="Connect";self.connect.isEnabled=true;self.connect.keyEquivalent="\r"
                self.baseFields.forEach{$0.isEnabled=true};self.sessionControls.forEach{$0.isEnabled=false}
                self.loadRememberedPassword();self.updateDeviceControls();self.placeholder.isHidden=false
                self.updateViewportUI();self.setSidebarHidden(false,persist:false)
                self.status.stringValue=intentional ? "Disconnected" : "Connection failed"
                self.status.toolTip=nil;self.window?.subtitle="Native remote desktop"
                self.placeholderTitle.stringValue=intentional ? "Ready when you are." : "Couldn’t connect."
                self.placeholderDetail.stringValue=intentional ? "Connect again to resume your remote session." : reason
                self.metrics.stringValue="ARM64  ·  Metal";self.connectionSize = .zero
                self.window?.makeFirstResponder(self.password)
            }
            self.refreshScreenCards()
        }
        let profile=activate ? quality.indexOfSelectedItem : connectionPreferences.load(host:address,port:number).qualityIndex
        let index=max(0,min(3,profile))
        if !next.start(host:address,port:number,password:value,viewOnly:!activate || viewOnly.state == .on,
                       quality:[8,-1,5,8][index],compression:index == 3 ? 3 : 1) {
            passwordToRemember=nil;computers.removeValue(forKey:key);computerMessages[key]="Unavailable"
            if activate {
                session=nil;connected=false;frameRouter.select(nil) { desktop.clear() }
                baseFields.forEach{$0.isEnabled=true};updateDeviceControls()
                connect.title="Connect";connect.isEnabled=true;connect.keyEquivalent="\r";progress.stopAnimation(nil)
                status.stringValue="Connection failed";placeholderTitle.stringValue="Couldn’t connect."
                placeholderDetail.stringValue="Could not start the connection worker. Try connecting again."
            }
        } else { _=next.setUpdateInterval(milliseconds:activate ? 0 : previewIntervalMilliseconds) }
        refreshScreenCards()
    }

    private func showConnectedComputer(_ computer:WorkspaceComputer) {
        connected=true;remoteName=computer.name;connectionSize=computer.size
        networkLatency=computer.session.networkLatency();renderNetworkLatency(networkLatency,visible:true)
        status.stringValue=computer.name == computer.host ? computer.host : "\(computer.name) · \(computer.host)"
        status.toolTip="Connected to \(computer.host):\(computer.port)";window?.subtitle="\(computer.host):\(computer.port)"
        placeholder.isHidden=true;progress.stopAnimation(nil)
        connect.title="Disconnect";connect.isEnabled=true;connect.keyEquivalent=""
        baseFields.forEach{$0.isEnabled=false};sessionControls.forEach{$0.isEnabled=true}
        if viewOnly.state == .on { sessionControls[0].isEnabled=false;sessionControls[1].isEnabled=false }
        if let note=computer.credentialNote { passwordHint.stringValue=note }
        window?.makeFirstResponder(desktop);updateViewportUI();clipboardCount = -1;syncClipboard()
    }

    private func demoteCurrentComputer() {
        desktop.releaseKeys();persistConnectionPreferences()
        if let current=session {
            current.viewOnly(true);_=current.setUpdateInterval(milliseconds:previewIntervalMilliseconds)
            if let key=endpointIdentity,let computer=computers[key],devices.find(host:computer.host,port:computer.port) == nil {
                computer.phase = .closing;current.stop()
            }
        }
        frameRouter.select(nil) {}
        session=nil;connected=false
    }

    private func promoteComputer(_ computer:WorkspaceComputer) {
        if session !== computer.session { demoteCurrentComputer() }
        selectedBrowserID=nil;defaults.removeObject(forKey:"workspaceSelectedBrowser")
        vncPane.isHidden=false;webHost.isHidden=true
        browserPanes.values.forEach{$0.setActive(false)}
        host.stringValue=computer.host;port.stringValue=String(computer.port)
        session=computer.session;connected=computer.phase == .connected
        defaults.set(computer.host,forKey:"server");defaults.set(String(computer.port),forKey:"port")
        restoreConnectionPreferences()
        frameRouter.select(computer.token) { desktop.clear() }
        _=computer.session.setUpdateInterval(milliseconds:0)
        computer.session.viewOnly(viewOnly.state == .on)
        // Native authentication may have finished before its main-queue state
        // callback. Always request a full image when promoting a preview.
        computer.session.refresh()
        if computer.phase == .connected { showConnectedComputer(computer) }
        else {
            baseFields.forEach{$0.isEnabled=false};progress.startAnimation(nil)
            connect.title="Cancel";connect.isEnabled=true;connect.keyEquivalent="\u{1b}"
            status.stringValue="Connecting to \(computer.host)…";status.toolTip=nil
            placeholder.isHidden=false;placeholderTitle.stringValue="Connecting…"
            placeholderDetail.stringValue="Opening a direct connection to \(computer.host):\(computer.port)."
        }
        refreshDevicePicker();refreshScreenCards()
    }

    private func showWorkspaceNotice(_ message:String) {
        workspaceNotice.stringValue=message;workspaceNotice.isHidden=message.isEmpty
    }

    @objc private func toggleConnectionSettings() {
        if selectedBrowserID != nil {
            showComputerEndpoint(autoConnect:false)
            settingsGroup.isHidden=false;settingsDisclosure.state = .on
        } else { settingsGroup.isHidden=settingsDisclosure.state != .on }
    }

    @objc private func addScreenSelected() {
        switch addScreen.indexOfSelectedItem {
        case 1: prepareNewComputer()
        case 2: presentWebsiteEditor()
        default: break
        }
        addScreen.selectItem(at:0)
    }

    private func prepareNewComputer() {
        demoteCurrentComputer();selectedBrowserID=nil
        defaults.removeObject(forKey:"workspaceSelectedBrowser")
        browserPanes.values.forEach{$0.setActive(false)}
        vncPane.isHidden=false;webHost.isHidden=true
        host.stringValue="";port.stringValue="5900";pendingAlias=nil
        frameRouter.select(nil) { desktop.clear() }
        loadRememberedPassword();restoreConnectionPreferences();resetDisconnectedControls()
        refreshDevicePicker();refreshScreenCards()
        settingsGroup.isHidden=false;settingsDisclosure.state = .on
        status.stringValue="New connection";placeholderTitle.stringValue="Add a computer."
        placeholderDetail.stringValue="Find a VNC server on your network or use its address."
        window?.makeFirstResponder(host)
    }

    private func resetDisconnectedControls() {
        connected=false;session=nil;progress.stopAnimation(nil)
        baseFields.forEach{$0.isEnabled=true};sessionControls.forEach{$0.isEnabled=false}
        connect.title="Connect";connect.isEnabled=true;connect.keyEquivalent="\r"
        renderNetworkLatency(.unavailable,visible:false)
        status.toolTip=nil;window?.subtitle="Native remote desktop"
        placeholder.isHidden=false;metrics.stringValue="ARM64  ·  Metal";connectionSize = .zero
        updateViewportUI();updateDeviceControls()
    }

    private func selectComputer(id:String,autoConnect:Bool=true) {
        guard let device=devices.devices.first(where:{$0.id == id}) else { return }
        if selectedBrowserID == nil,endpointIdentity == WorkspaceComputer.key(host:device.host,port:device.port),session != nil {
            window?.makeFirstResponder(connected ? desktop : password);return
        }
        demoteCurrentComputer()
        host.stringValue=device.host;port.stringValue=String(device.port);pendingAlias=nil
        showComputerEndpoint(autoConnect:autoConnect)
    }

    private func showComputerEndpoint(autoConnect:Bool) {
        selectedBrowserID=nil;defaults.removeObject(forKey:"workspaceSelectedBrowser")
        browserPanes.values.forEach{$0.setActive(false)}
        vncPane.isHidden=false;webHost.isHidden=true
        if let key=endpointIdentity,let computer=computers[key] { promoteComputer(computer);return }
        frameRouter.select(nil) { desktop.clear() }
        resetDisconnectedControls();loadRememberedPassword();restoreConnectionPreferences()
        defaults.set(host.stringValue,forKey:"server");defaults.set(port.stringValue,forKey:"port")
        refreshDevicePicker();refreshScreenCards()
        status.stringValue="Ready to connect"
        placeholderTitle.stringValue="Your desktop, one connection away."
        placeholderDetail.stringValue="Connect to \(currentDevice?.name ?? "your VNC server") to see and control its screen here."
        settingsGroup.isHidden=false;settingsDisclosure.state = .on
        if autoConnect,rememberPassword.state == .on { toggleConnection() }
        else { window?.makeFirstResponder(host) }
    }

    private func disconnectComputer(key:String) {
        guard let computer=computers[key] else { return }
        if isSelected(computer) { desktop.releaseKeys();connect.isEnabled=false;status.stringValue="Disconnecting…" }
        computer.phase = .closing;computer.session.stop();refreshScreenCards()
    }

    private func startSavedPreviews() {
        for device in devices.devices {
            let key=WorkspaceComputer.key(host:device.host,port:device.port)
            guard computers[key] == nil else { continue }
            do {
                guard let secret=try passwordStore.read(host:device.host,port:device.port) else { continue }
                let activate=selectedBrowserID == nil && endpointIdentity == key && session == nil
                startComputer(host:device.host,port:device.port,password:secret,remember:false,activate:activate)
            } catch { computerMessages[key]="Saved password unavailable" }
        }
        if let id=defaults.string(forKey:"workspaceSelectedBrowser"),browserStore.screens.contains(where:{$0.id == id}) {
            selectBrowser(id:id)
        }
        for screen in browserStore.screens.prefix(maximumLoadedBrowsers) where browserPanes[screen.id] == nil {
            _=makeBrowserPane(screen)
        }
        refreshScreenCards()
    }

    private func previewAge(_ timestamp:TimeInterval?) -> String {
        guard let timestamp=timestamp else { return "waiting for screen" }
        let seconds=max(0,Int(ProcessInfo.processInfo.systemUptime-timestamp))
        if seconds < 2 { return "just sampled" }
        if seconds < 60 { return "sampled \(seconds)s ago" }
        return "sampled \(seconds/60)m ago"
    }

    private func refreshScreenCards() {
        updateWorkspaceMenu()
        let keepComputers=Set(devices.devices.map{$0.id}),keepBrowsers=Set(browserStore.screens.map{$0.id})
        computerCards=computerCards.filter{keepComputers.contains($0.key)}
        browserCards=browserCards.filter{keepBrowsers.contains($0.key)}
        var ordered:[ScreenCardView]=[]
        for device in devices.devices {
            let key=WorkspaceComputer.key(host:device.host,port:device.port)
            let card:ScreenCardView
            if let existing=computerCards[device.id] { card=existing }
            else {
                card=ScreenCardView(identifier:"computer:"+device.id,title:device.name,kind:.computer)
                card.onSelect={ [weak self] in self?.selectComputer(id:device.id) }
                card.onEdit={ [weak self] in self?.renameComputer(id:device.id) }
                card.onRemove={ [weak self] in self?.removeComputerProfile(id:device.id) }
                computerCards[device.id]=card
            }
            card.onDisconnect=computers[key] == nil ? nil : { [weak self] in self?.disconnectComputer(key:key) }
            let text:String
            if let computer=computers[key] {
                switch computer.phase {
                case .connecting: text="Connecting…"
                case .closing: text="Disconnecting…"
                case .connected: text=isSelected(computer) ? "Viewing · preview paused" : "Connected · "+previewAge(computerSampleTimes[key])
                }
            } else {
                text=(computerMessages[key] ?? "Not connected")+(computerImages[key] == nil ? "" : " · last capture")
            }
            card.update(title:device.name,status:text,image:computerImages[key],selected:selectedBrowserID == nil && endpointIdentity == key)
            ordered.append(card)
        }
        for screen in browserStore.screens {
            let card:ScreenCardView
            if let existing=browserCards[screen.id] { card=existing }
            else {
                card=ScreenCardView(identifier:"browser:"+screen.id,title:screen.title,kind:.browser)
                card.onSelect={ [weak self] in self?.selectBrowser(id:screen.id) }
                card.onEdit={ [weak self] in self?.presentWebsiteEditor(id:screen.id) }
                card.onRemove={ [weak self] in self?.removeBrowser(id:screen.id) }
                browserCards[screen.id]=card
            }
            let text:String
            if let pane=browserPanes[screen.id] { text=pane.hasError ? "Page unavailable" : "\(screen.tabs.count) \(screen.tabs.count == 1 ? "tab" : "tabs") · "+(selectedBrowserID == screen.id ? "preview paused" : previewAge(browserSampleTimes[screen.id])) }
            else { text="Sleeping · select to resume" }
            card.update(title:screen.title,status:text,image:browserImages[screen.id],selected:selectedBrowserID == screen.id)
            ordered.append(card)
        }
        ordered=ordered.enumerated().sorted { left,right in
            let a=screenRank(left.element),b=screenRank(right.element)
            return a == b ? left.offset < right.offset : a < b
        }.map{$0.element}
        let wanted=ordered.map{$0.screenIdentifier}
        if wanted != cardOrder {
            cardOrder=wanted;cards.setViews(ordered.map{$0 as NSView},in:.center)
            for view in ordered { view.widthAnchor.constraint(equalTo:cards.widthAnchor).isActive=true }
        }
    }

    private func screenRank(_ card:ScreenCardView) -> Int {
        if card.kind == .computer {
            let id=String(card.screenIdentifier.dropFirst("computer:".count))
            guard let device=devices.devices.first(where:{$0.id == id}),
                  let computer=computers[WorkspaceComputer.key(host:device.host,port:device.port)] else { return 3 }
            switch computer.phase {
            case .connected, .connecting: return 1
            case .closing: return 3
            }
        }
        let id=String(card.screenIdentifier.dropFirst("browser:".count))
        guard let pane=browserPanes[id],!pane.hasError else { return 3 }
        return 1
    }

    private func updateWorkspaceMenu() {
        let active=selectedBrowserID != nil
        guard menuBrowserActive != active,
              let item=NSApp.mainMenu?.items.first(where:{$0.identifier?.rawValue == "workspaceEditMenu"}),
              let menu=item.submenu else { return }
        menuBrowserActive=active;item.isHidden = !active
        for command in menu.items {
            if let key=command.representedObject as? String { command.keyEquivalent=active ? key : "" }
        }
    }

    private func renameComputer(id:String) {
        guard let device=devices.devices.first(where:{$0.id == id}),let window=window,window.attachedSheet == nil else { return }
        let alert=NSAlert();alert.messageText="Name this computer"
        alert.informativeText="Choose a name you recognize. Its connection stays open."
        let name=NSTextField(string:device.name);name.frame=NSRect(x:0,y:0,width:300,height:28)
        alert.accessoryView=name;alert.addButton(withTitle:"Save");alert.addButton(withTitle:"Cancel")
        alert.beginSheetModal(for:window) { [weak self] response in
            guard let self=self,response == .alertFirstButtonReturn,
                  self.devices.devices.contains(where:{$0.id == id}),
                  let saved=self.devices.save(name:name.stringValue,host:device.host,port:device.port) else { return }
            let key=WorkspaceComputer.key(host:device.host,port:device.port)
            self.computers[key]?.name=saved.name
            if let computer=self.computers[key],self.isSelected(computer),computer.phase == .connected {
                self.status.stringValue="\(saved.name) · \(saved.host)"
            }
            self.refreshDevicePicker()
        }
        alert.window.makeFirstResponder(name);name.selectText(nil)
    }

    private func presentWebsiteEditor(id:String?=nil) {
        guard let window=window,window.attachedSheet == nil else { return }
        let current=id.flatMap{identifier in browserStore.screens.first{$0.id == identifier}}
        let alert=NSAlert();alert.messageText=current == nil ? "Add a browser window" : "Edit browser window"
        alert.informativeText="Each browser window can keep multiple tabs. Its website data stays separate from Safari and Chrome."
        let address=NSTextField(string:current?.url ?? "");address.placeholderString="Starting URL (optional)"
        let name=NSTextField(string:current?.title ?? "");name.placeholderString="Browser name (optional)"
        let fields=NSStackView(views:[address,name]);fields.orientation = .vertical;fields.spacing=10
        fields.frame=NSRect(x:0,y:0,width:360,height:72)
        for field in [address,name] { field.widthAnchor.constraint(equalToConstant:360).isActive=true;field.heightAnchor.constraint(equalToConstant:30).isActive=true }
        alert.accessoryView=fields;alert.addButton(withTitle:current == nil ? "Add Browser" : "Save");alert.addButton(withTitle:"Cancel")
        alert.beginSheetModal(for:window) { [weak self] response in
            guard let self=self,response == .alertFirstButtonReturn else { return }
            do {
                let screen:BrowserScreen
                if let current=current {
                    guard let edited=try self.browserStore.update(id:current.id,title:name.stringValue,url:address.stringValue.isEmpty && current.url.isEmpty ? nil : address.stringValue) else { return }
                    screen=edited
                    if screen.url != current.url,!screen.url.isEmpty,let url=URL(string:screen.url) { self.browserPanes[screen.id]?.load(url) }
                } else if address.stringValue.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                    let tab=BrowserTab(id:UUID().uuidString,title:"New tab",url:"")
                    screen=try self.browserStore.add(title:name.stringValue,tabs:[tab],selectedTabID:tab.id)
                } else { screen=try self.browserStore.add(title:name.stringValue,url:address.stringValue) }
                self.selectBrowser(id:screen.id)
            } catch { DispatchQueue.main.async { self.showError(error.localizedDescription) } }
        }
        alert.window.makeFirstResponder(address);address.selectText(nil)
    }

    private func makeBrowserPane(_ screen:BrowserScreen) -> BrowserScreenPane {
        if let pane=browserPanes[screen.id] { return pane }
        while browserPanes.count >= maximumLoadedBrowsers {
            guard let oldest=browserPanes.keys.filter({$0 != selectedBrowserID}).min(by:{browserUse[$0,default:0] < browserUse[$1,default:0]}) else { break }
            browserPanes[oldest]?.stop();browserPanes[oldest]?.removeFromSuperview()
            browserPanes.removeValue(forKey:oldest);browserUse.removeValue(forKey:oldest);browserSnapshotInFlight.removeValue(forKey:oldest)
        }
        let pane=BrowserScreenPane(screen:screen,dataStore:browserWebsiteDataStore)
        pane.translatesAutoresizingMaskIntoConstraints=false;webHost.addSubview(pane)
        NSLayoutConstraint.activate([pane.leadingAnchor.constraint(equalTo:webHost.leadingAnchor),pane.trailingAnchor.constraint(equalTo:webHost.trailingAnchor),pane.topAnchor.constraint(equalTo:webHost.topAnchor),pane.bottomAnchor.constraint(equalTo:webHost.bottomAnchor)])
        pane.isHidden=true;pane.setActive(false);pane.setSidebarVisible(!sidebarHidden)
        pane.onNavigation={ [weak self,weak pane] _,_ in
            guard let self=self,let pane=pane,self.browserPanes[screen.id] === pane else { return }
            self.refreshScreenCards()
        }
        pane.onTabsChanged={ [weak self,weak pane] tabs,selectedID in
            guard let self=self,let pane=pane,self.browserPanes[screen.id] === pane else { return }
            do { _=try self.browserStore.updateTabs(id:screen.id,tabs:tabs,selectedTabID:selectedID) }
            catch { self.showWorkspaceNotice(error.localizedDescription) }
            self.refreshScreenCards()
        }
        pane.onToggleSidebar={ [weak self] in self?.toggleSidebar() }
        pane.onFullScreen={ [weak self] in self?.fullScreen() }
        pane.onStateChanged={ [weak self] in self?.refreshScreenCards() }
        browserPanes[screen.id]=pane
        browserUseSequence += 1;browserUse[screen.id]=browserUseSequence
        return pane
    }

    private func selectBrowser(id:String) {
        guard let screen=browserStore.screens.first(where:{$0.id == id}) else { return }
        if selectedBrowserID == nil { demoteCurrentComputer() }
        selectedBrowserID=id;defaults.set(id,forKey:"workspaceSelectedBrowser")
        browserUseSequence += 1;browserUse[id]=browserUseSequence
        let pane=makeBrowserPane(screen)
        vncPane.isHidden=true;webHost.isHidden=false
        for (identifier,other) in browserPanes { other.isHidden=identifier != id;other.setActive(identifier == id) }
        pane.setSidebarVisible(!sidebarHidden);pane.focus()
        settingsGroup.isHidden=true;settingsDisclosure.state = .off
        window?.subtitle="Local browser · \(screen.title)"
        refreshScreenCards();window?.contentView?.layoutSubtreeIfNeeded();takeBrowserPreviews()
        if !sidebarHidden {
            if let card=browserCards[id] { _=card.scrollToVisible(card.bounds) }
        }
    }

    private func removeBrowser(id:String) {
        let selected=selectedBrowserID == id
        browserPanes[id]?.stop();browserPanes[id]?.removeFromSuperview();browserPanes.removeValue(forKey:id)
        browserUse.removeValue(forKey:id);browserSnapshotInFlight.removeValue(forKey:id)
        browserImages.removeValue(forKey:id);browserSampleTimes.removeValue(forKey:id);browserAttemptTimes.removeValue(forKey:id);browserStore.remove(id:id)
        if selected {
            if let next=browserStore.screens.first { selectBrowser(id:next.id) }
            else { showComputerEndpoint(autoConnect:false) }
        }
        refreshScreenCards()
    }

    private func takeBrowserPreviews() {
        guard !sidebarHidden else { return }
        let now=ProcessInfo.processInfo.systemUptime
        for (id,pane) in browserPanes {
            if id == selectedBrowserID {
                if browserImages[id] != nil || pane.webView.isLoading { continue }
            }
            guard browserSnapshotInFlight[id] == nil,now-browserAttemptTimes[id,default:0] >= previewInterval else { continue }
            browserAttemptTimes[id]=now
            let token=UUID();browserSnapshotInFlight[id]=token
            pane.takePreview { [weak self,weak pane] image in
                guard let self=self,let pane=pane,self.browserPanes[id] === pane,self.browserSnapshotInFlight[id] == token else { return }
                self.browserSnapshotInFlight.removeValue(forKey:id)
                if id == self.selectedBrowserID,self.browserImages[id] != nil { return }
                if let image=image {
                    self.browserImages[id]=image
                    self.browserSampleTimes[id]=pane.lastPreviewSampleTime
                }
                self.refreshScreenCards()
            }
        }
    }

    private func removeComputerProfile(id:String) {
        guard let device=devices.devices.first(where:{$0.id == id}) else { return }
        let key=WorkspaceComputer.key(host:device.host,port:device.port)
        if let computer=computers[key] {
            if isSelected(computer) {
                desktop.releaseKeys();frameRouter.select(nil) { desktop.clear() };resetDisconnectedControls()
            }
            computers.removeValue(forKey:key);computer.session.stop()
        }
        var credentialError:Error?
        do { try passwordStore.remove(host:device.host,port:device.port) } catch { credentialError=error }
        connectionPreferences.remove(host:device.host,port:device.port);devices.remove(id:device.id)
        computerImages.removeValue(forKey:key);computerSampleTimes.removeValue(forKey:key);computerMessages.removeValue(forKey:key)
        if endpointIdentity == key {
            password.stringValue="";rememberPassword.state = .off;credentialEndpoint=endpointIdentity
            restoreConnectionPreferences()
            if let error=credentialError {
                status.stringValue="Device removed · saved password retained"
                passwordHint.stringValue="Device removed. Its saved password could not be removed and remains on this Mac. "+error.localizedDescription
            } else { status.stringValue="Device and its saved password removed";passwordHint.stringValue="Saved password removed." }
        }
        if credentialError != nil { showWorkspaceNotice("Computer removed. Its protected saved password remains on this Mac.") }
        refreshDevicePicker();refreshScreenCards()
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
        if let id=selectedBrowserID { browserPanes[id]?.focus() }
        else { window?.makeFirstResponder(connected || sidebarHidden ? desktop : password) }
    }
    private func setSidebarHidden(_ hidden: Bool,persist: Bool) {
        sidebarHidden=hidden; sidebar.isHidden=hidden; sidebarWidth.constant=hidden ? 0 : 288
        sidebarToggle.state=hidden ? .off : .on
        sidebarToggle.title=hidden ? "Show settings" : "Hide settings"
        sidebarToggle.setAccessibilityLabel(sidebarToggle.title)
        sidebarToggle.toolTip="\(hidden ? "Show" : "Hide") connection sidebar (Control–Command–S)"
        if persist {
            defaults.set(hidden,forKey:"sidebarHidden")
            if window?.styleMask.contains(.fullScreen) == true { sidebarHiddenBeforeFullScreen=hidden }
        }
        window?.contentView?.layoutSubtreeIfNeeded()
        desktop.updateCanvas(); updateViewportUI()
        browserPanes.values.forEach{$0.setSidebarVisible(!hidden)}
        if !hidden { takeBrowserPreviews() }
    }
    @objc func fullScreen() { window?.toggleFullScreen(nil) }
    @objc func sendCAD() { if selectedBrowserID == nil,viewOnly.state != .on { desktop.releaseKeys(); session?.controlAltDelete(); window?.makeFirstResponder(desktop) } }
    @objc func sendClipboard() {
        guard connected, viewOnly.state != .on, let text=NSPasteboard.general.string(forType:.string) else { return }
        session?.clipboard(text); clipboardCount=NSPasteboard.general.changeCount; window?.makeFirstResponder(desktop)
    }
    @objc func refreshScreen() { guard selectedBrowserID == nil else { return };session?.refresh(); window?.makeFirstResponder(desktop) }
    @objc private func focusChanged() { if window?.firstResponder === desktop { syncClipboard() } }
    private func syncClipboard() {
        guard connected, clipboard.state == .on, viewOnly.state != .on, NSApp.isActive, window?.isKeyWindow == true, clipboardCount != NSPasteboard.general.changeCount else { return }
        if let text=NSPasteboard.general.string(forType:.string) { session?.clipboard(text) }
        clipboardCount=NSPasteboard.general.changeCount
    }
    private func tick() {
        takeBrowserPreviews();refreshScreenCards()
        guard connected else { return }
        networkLatency=session?.networkLatency() ?? .unavailable
        let current=desktop.framesReceived
        let fps=max(0,current-lastFrames); lastFrames=current
        updateMetrics(fps:fps)
        if window?.firstResponder === desktop { syncClipboard() }
    }
    private func updateMetrics(fps: Int? = nil) {
        guard connected else { return }
        renderNetworkLatency(networkLatency,visible:true)
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
    private func renderNetworkLatency(_ snapshot: NetworkLatency,visible: Bool) {
        latency.stringValue=snapshot.title;latency.toolTip=snapshot.toolTip;latency.isHidden = !visible
    }
#if APP_UI_HARNESS
    var testingScreenOrder:[String] { cardOrder }
    var testingPreviewInterval:TimeInterval { previewInterval }
    var testingComputerPreviewCount:Int { computerImages.count }
    var testingBrowserPreviewCount:Int { browserImages.count }
    var testingComputerCount:Int { computers.count }
    var testingSelectedBrowserID:String? { selectedBrowserID }
    var testingCurrentSession:VNCSession? { session }
    var testingDesktop:MetalDesktop { desktop }
    var testingBrowserPreviewSampleTimes:[String:TimeInterval] { browserSampleTimes }
    func testingComputerSession(id:String)->VNCSession? {
        guard let device=devices.devices.first(where:{$0.id == id}) else { return nil }
        return computers[WorkspaceComputer.key(host:device.host,port:device.port)]?.session
    }
    func testingEditBrowser(id:String,title:String,url:String)throws {
        guard let screen=try browserStore.update(id:id,title:title,url:url) else { return }
        if !screen.url.isEmpty,let address=URL(string:screen.url) { browserPanes[id]?.load(address) }
        refreshScreenCards()
    }
    func testingAddBrowser(title:String,url:String)throws->String {
        let screen=try browserStore.add(title:title,url:url);selectBrowser(id:screen.id);return screen.id
    }
    func testingSelectBrowser(id:String) { selectBrowser(id:id) }
    func testingSelectComputer(id:String) { selectComputer(id:id) }
    func testingStartSavedPreviews() { startSavedPreviews() }
    func testingBrowserPane(id:String)->BrowserScreenPane? { browserPanes[id] }
    func testingRemoveBrowser(id:String) { removeBrowser(id:id) }
    func testingRemoveComputer(id:String) { removeComputerProfile(id:id) }
    func testingWorkspaceTick() { tick() }
    func testingShowNetworkLatency(_ snapshot: NetworkLatency?,connectionName: String?=nil) {
        if let connectionName=connectionName { status.stringValue=connectionName }
        renderNetworkLatency(snapshot ?? .unavailable,visible:snapshot != nil)
        window?.contentView?.layoutSubtreeIfNeeded()
    }
#endif
    @objc func toggleFrameRate(_ sender: NSMenuItem) {
        defaults.set(!showFrameRate,forKey:"showFrameRate")
        sender.state = showFrameRate ? .on : .off
        updateMetrics()
    }
    func windowDidResignKey(_ notification: Notification) { desktop.releaseKeys() }
    func windowDidResize(_ notification: Notification) { desktop.updateCanvas(); updateMetrics() }
    func windowDidEnterFullScreen(_ notification: Notification) { sidebarHiddenBeforeFullScreen=sidebarHidden; setSidebarHidden(true,persist:false) }
    func windowDidExitFullScreen(_ notification: Notification) { setSidebarHidden(sidebarHiddenBeforeFullScreen,persist:false) }
    private func persistWindowPlacement() {
        guard remembersWindowFrame,let window=window else { return }
        WindowPlacement.save(window)
    }
    func windowWillClose(_ notification: Notification) { stop();NSApp.terminate(nil) }
    func stop() {
        persistWindowPlacement();persistConnectionPreferences();discoveryController?.dismiss();desktop.releaseKeys()
        frameRouter.select(nil) {}
        computers.values.forEach{$0.session.stop()};computers.removeAll();session=nil;connected=false
        browserPanes.values.forEach{$0.stop()}
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var controller: ViewerController?
#if APP_UI_HARNESS
    func testingInstallMenu(controller: ViewerController) {
        self.controller=controller;buildMenu()
    }
#endif
    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        do {
            controller=try ViewerController(); NSApp.activate(ignoringOtherApps:true)
            if CommandLine.arguments.contains("--find-servers") { controller?.findNetworkServers() }
        }
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
        let editItem=NSMenuItem();editItem.title="Edit";menu.addItem(editItem)
        editItem.identifier=NSUserInterfaceItemIdentifier("workspaceEditMenu");editItem.isHidden=true
        let edit=NSMenu(title:"Edit");editItem.submenu=edit
        edit.addItem(withTitle:"Undo",action:Selector(("undo:")),keyEquivalent:"z")
        let redo=edit.addItem(withTitle:"Redo",action:Selector(("redo:")),keyEquivalent:"Z")
        redo.keyEquivalentModifierMask=[.shift,.command]
        edit.addItem(.separator())
        edit.addItem(withTitle:"Cut",action:#selector(NSText.cut(_:)),keyEquivalent:"x")
        edit.addItem(withTitle:"Copy",action:#selector(NSText.copy(_:)),keyEquivalent:"c")
        edit.addItem(withTitle:"Paste",action:#selector(NSText.paste(_:)),keyEquivalent:"v")
        edit.addItem(withTitle:"Select All",action:#selector(NSText.selectAll(_:)),keyEquivalent:"a")
        // Keep the established VNC Command-to-Control path untouched. Browser
        // edit shortcuts exist only while a local browser card is selected.
        for item in edit.items where !item.keyEquivalent.isEmpty {
            item.representedObject=item.keyEquivalent;item.keyEquivalent=""
        }
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
        if controller?.isBrowserActive == true,let action=menuItem.action,
           [#selector(connection),#selector(cad),#selector(paste),#selector(refresh),#selector(frameRate(_:)),#selector(automaticZoom),#selector(fitZoom),#selector(actualSize),#selector(zoomIn),#selector(zoomOut),#selector(handTool)].contains(action) { return false }
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
