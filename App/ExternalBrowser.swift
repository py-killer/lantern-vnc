// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit

enum BrowserApplication: String, Codable, CaseIterable {
    case safari, chrome
    var bundleIdentifier: String { self == .safari ? "com.apple.Safari" : "com.google.Chrome" }
    var displayName: String { self == .safari ? "Safari" : "Google Chrome" }
    var installedURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier:bundleIdentifier) }
}

enum ExternalBrowserStatus: Equatable {
    case ready, opening, running, closed, missing, failed(String)
}

/// Uses ordinary Launch Services only. No browser automation, Apple events,
/// profile access, remote-debugging flags, screen capture or synthetic input.
protocol ExternalBrowserLaunching {
    func applicationURL(bundleIdentifier: String) -> URL?
    func isRunning(bundleIdentifier: String) -> Bool
    func activate(bundleIdentifier: String) -> Bool
    func open(url: URL, applicationURL: URL, completion: @escaping (Result<Void,Error>) -> Void)
}

final class WorkspaceBrowserLauncher: ExternalBrowserLaunching {
    func applicationURL(bundleIdentifier: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier:bundleIdentifier)
    }
    func isRunning(bundleIdentifier: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier:bundleIdentifier).contains { !$0.isTerminated }
    }
    func activate(bundleIdentifier: String) -> Bool {
        guard let app=NSRunningApplication.runningApplications(withBundleIdentifier:bundleIdentifier).first(where:{!$0.isTerminated}) else { return false }
        return app.activate(options:[.activateIgnoringOtherApps])
    }
    func open(url: URL, applicationURL: URL, completion: @escaping (Result<Void,Error>) -> Void) {
        let configuration=NSWorkspace.OpenConfiguration()
        configuration.activates=true
        configuration.createsNewApplicationInstance=false
        configuration.promptsUserIfNeeded=false
        NSWorkspace.shared.open([url],withApplicationAt:applicationURL,configuration:configuration) { app,error in
            if let error=error { completion(.failure(error)) }
            else if app != nil { completion(.success(())) }
            else { completion(.failure(NSError(domain:"LanternExternalBrowser",code:1,userInfo:[NSLocalizedDescriptionKey:"The browser did not report a successful open."]))) }
        }
    }
}

/// One manager per saved external-browser card. All state is main-thread-only;
/// NSWorkspace completions are normalized onto main before touching it.
final class ExternalBrowserManager {
    let application: BrowserApplication
    var onStatusChanged: ((ExternalBrowserStatus) -> Void)?
    private(set) var status: ExternalBrowserStatus = .ready
    private(set) var hasOpenedWebsite=false
    private let launcher: ExternalBrowserLaunching
    private var generation: UInt64=0
    private var pending=false

    init(application: BrowserApplication,launcher: ExternalBrowserLaunching=WorkspaceBrowserLauncher()) {
        self.application=application;self.launcher=launcher
        refreshStatus()
    }
    /// The first selection opens the saved URL. Subsequent selections only
    /// activate the actual browser while it remains running: no duplicate tabs.
    func select(website: URL) {
        precondition(Thread.isMainThread)
        guard !pending else { return }
        if hasOpenedWebsite,launcher.isRunning(bundleIdentifier:application.bundleIdentifier) {
            if launcher.activate(bundleIdentifier:application.bundleIdentifier) { publish(.running) }
            else { publish(.failed("Couldn’t switch to \(application.displayName). Try again or open it directly.")) }
        } else { openWebsite(website) }
    }
    /// An explicit user action intentionally opens the supplied address again.
    func openWebsite(_ website: URL) {
        precondition(Thread.isMainThread)
        guard Self.isValidWebsite(website) else {
            invalidatePending();publish(.failed("Use an HTTP or HTTPS website address without embedded credentials."));return
        }
        guard let location=launcher.applicationURL(bundleIdentifier:application.bundleIdentifier) else {
            invalidatePending();publish(.missing);return
        }
        generation &+= 1;let request=generation;pending=true;publish(.opening)
        guard generation == request,pending else { return }
        launcher.open(url:website,applicationURL:location) { [weak self] result in
            let complete = { [weak self] in
                guard let self=self,self.generation == request,self.pending else { return }
                self.pending=false
                switch result {
                case .success:
                    self.hasOpenedWebsite=true
                    self.refreshStatus()
                case .failure(let error):
                    self.publish(.failed("Couldn’t open \(self.application.displayName). "+error.localizedDescription))
                }
            }
            if Thread.isMainThread { complete() } else { DispatchQueue.main.async(execute:complete) }
        }
    }
    func refreshStatus() {
        precondition(Thread.isMainThread)
        guard !pending else { return }
        let running=launcher.isRunning(bundleIdentifier:application.bundleIdentifier)
        if !running,launcher.applicationURL(bundleIdentifier:application.bundleIdentifier) == nil { publish(.missing) }
        else if hasOpenedWebsite,!running { publish(.closed) }
        else if case .failed = status { return } // Keep an error visible until an explicit retry.
        else { publish(hasOpenedWebsite && running ? .running : .ready) }
    }
    /// Ignores stale completion callbacks. Launch Services cannot retract an
    /// external open already submitted to macOS, so this is not process control.
    func cancelPending() {
        precondition(Thread.isMainThread)
        invalidatePending();refreshStatus()
    }
    private func invalidatePending() { generation &+= 1;pending=false }
    private func publish(_ value: ExternalBrowserStatus) {
        guard status != value else { return }
        status=value;onStatusChanged?(value)
    }
    private static func isValidWebsite(_ url: URL) -> Bool {
        guard let components=URLComponents(url:url,resolvingAgainstBaseURL:false),
              let scheme=components.scheme?.lowercased(),["https","http"].contains(scheme),
              let host=components.host,!host.isEmpty,components.user == nil,components.password == nil,
              components.port.map({(1...65535).contains($0)}) ?? true else { return false }
        return url.absoluteString.utf8.count <= 8192 && !url.absoluteString.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

/// A truthful local launcher panel, never a screenshot or embedded substitute
/// for Safari/Chrome. The user's actual browser keeps its own profile/session.
final class ExternalBrowserPanel: NSView {
    let application: BrowserApplication
    var onOpenOrSwitch: (() -> Void)?
    var onOpenWebsite: (() -> Void)?
    var onChangeURL: (() -> Void)?
    var onToggleSidebar: (() -> Void)?
    private let statusLabel=NSTextField(wrappingLabelWithString:"")
    private let address=NSTextField(labelWithString:"")
    private let open=NSButton(title:"",target:nil,action:nil)
    private let website=NSButton(title:"Open Website",target:nil,action:nil)
    private let edit=NSButton(title:"Change URL…",target:nil,action:nil)
    private let sidebar=NSButton(image:NSImage(systemSymbolName:"sidebar.left",accessibilityDescription:"Show or hide sidebar")!,target:nil,action:nil)

    init(application: BrowserApplication) {
        self.application=application;super.init(frame:.zero)
        identifier = .init("externalBrowserPanel")
        sidebar.identifier = .init("externalBrowserSidebarToggle");sidebar.bezelStyle = .texturedRounded
        sidebar.target=self;sidebar.action=#selector(toggleSidebar)
        sidebar.translatesAutoresizingMaskIntoConstraints=false;addSubview(sidebar)
        let icon:NSImage
        if let location=application.installedURL { icon=NSWorkspace.shared.icon(forFile:location.path) }
        else { icon=NSImage(systemSymbolName:"globe",accessibilityDescription:nil) ?? NSImage() }
        let image=NSImageView(image:icon);image.imageScaling = .scaleProportionallyDown
        image.setAccessibilityElement(false);image.widthAnchor.constraint(equalToConstant:56).isActive=true;image.heightAnchor.constraint(equalToConstant:56).isActive=true
        let title=NSTextField(labelWithString:application.displayName);title.font = .systemFont(ofSize:24,weight:.semibold)
        let detail=NSTextField(wrappingLabelWithString:"Opens the installed browser with its own profile, extensions and logins. Its window stays outside Lantern.")
        detail.font = .systemFont(ofSize:13);detail.textColor = .secondaryLabelColor;detail.alignment = .center
        address.identifier = .init("externalBrowserURL");address.font = .systemFont(ofSize:13);address.lineBreakMode = .byTruncatingMiddle
        address.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        statusLabel.identifier = .init("externalBrowserStatus");statusLabel.font = .systemFont(ofSize:12);statusLabel.textColor = .secondaryLabelColor;statusLabel.alignment = .center;statusLabel.maximumNumberOfLines=3
        let note=NSTextField(wrappingLabelWithString:"Switch brings the browser app forward. It cannot guarantee a particular window, tab or profile. Use Open Website to open this address again.")
        note.font = .systemFont(ofSize:11);note.textColor = .secondaryLabelColor;note.alignment = .center
        for (button,id,action) in [(open,"externalBrowserOpenOrSwitch",#selector(openOrSwitch)),(website,"externalBrowserOpenWebsite",#selector(openWebsite)),(edit,"externalBrowserChangeURL",#selector(changeURL))] {
            button.identifier = .init(id);button.bezelStyle = .rounded;button.target=self;button.action=action
        }
        open.bezelColor = .controlAccentColor
        let buttons=NSStackView(views:[open,website,edit]);buttons.spacing=8;buttons.alignment = .centerY
        let content=NSStackView(views:[image,title,detail,address,statusLabel,buttons,note]);content.orientation = .vertical;content.spacing=10;content.alignment = .centerX
        content.translatesAutoresizingMaskIntoConstraints=false;addSubview(content)
        for label in [detail,statusLabel,note] { label.widthAnchor.constraint(equalTo:content.widthAnchor).isActive=true }
        address.widthAnchor.constraint(lessThanOrEqualTo:content.widthAnchor).isActive=true
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo:leadingAnchor,constant:10),sidebar.topAnchor.constraint(equalTo:topAnchor,constant:10),sidebar.widthAnchor.constraint(equalToConstant:32),sidebar.heightAnchor.constraint(equalToConstant:28),
            content.centerXAnchor.constraint(equalTo:centerXAnchor),
            content.widthAnchor.constraint(lessThanOrEqualToConstant:580),content.widthAnchor.constraint(lessThanOrEqualTo:widthAnchor,constant:-48),
            content.topAnchor.constraint(greaterThanOrEqualTo:sidebar.bottomAnchor,constant:12),content.bottomAnchor.constraint(lessThanOrEqualTo:bottomAnchor,constant:-20)
        ])
        let preferredWidth=content.widthAnchor.constraint(equalToConstant:580);preferredWidth.priority = .defaultHigh;preferredWidth.isActive=true
        let centered=content.centerYAnchor.constraint(equalTo:centerYAnchor);centered.priority = .defaultHigh;centered.isActive=true
        update(url:nil,status:.ready)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    func setSidebarVisible(_ visible: Bool) {
        sidebar.toolTip=visible ? "Hide connection sidebar" : "Show connection sidebar"
        sidebar.setAccessibilityLabel(sidebar.toolTip)
    }
    func update(url: URL?,status: ExternalBrowserStatus) {
        precondition(Thread.isMainThread)
        address.stringValue=url?.absoluteString ?? "Set a website address";address.toolTip=url?.absoluteString
        open.title="Open \(application.displayName)";open.isEnabled=true;website.isEnabled=true;edit.isEnabled=true
        switch status {
        case .ready:statusLabel.stringValue="Ready to open in \(application.displayName)."
        case .opening:statusLabel.stringValue="Opening \(application.displayName)…";open.isEnabled=false;website.isEnabled=false;edit.isEnabled=false
        case .running:statusLabel.stringValue="\(application.displayName) is running.";open.title="Switch to \(application.displayName)"
        case .closed:statusLabel.stringValue="\(application.displayName) is closed. Open it to resume."
        case .missing:statusLabel.stringValue="\(application.displayName) is not installed or could not be located.";open.isEnabled=false;website.isEnabled=false
        case .failed(let message):statusLabel.stringValue=message
        }
        if url == nil { open.isEnabled=false;website.isEnabled=false }
        statusLabel.toolTip=statusLabel.stringValue
        statusLabel.setAccessibilityValue(statusLabel.stringValue)
    }
    @objc private func openOrSwitch() { onOpenOrSwitch?() }
    @objc private func openWebsite() { onOpenWebsite?() }
    @objc private func changeURL() { onChangeURL?() }
    @objc private func toggleSidebar() { onToggleSidebar?() }
}
