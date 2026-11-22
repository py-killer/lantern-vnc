// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import WebKit

/// One retained browser card. Showing/hiding it never reloads the website or
/// changes the VNC renderer. Its persistent cookies belong to Lantern only.
final class BrowserScreenPane: NSView, WKNavigationDelegate, WKUIDelegate {
    var onNavigation: ((URL, String?) -> Void)?
    var onOpenURL: ((URL) -> Void)?
    var onToggleSidebar: (() -> Void)?
    var onFullScreen: (() -> Void)?
    var onStateChanged: (() -> Void)?
    let webView: WKWebView
    private(set) var isActive = false
    private(set) var currentURL: URL?
    private(set) var hasError = false
    private let address = NSTextField()
    private let back = NSButton(), forward = NSButton(), reload = NSButton()
    private let sidebar = NSButton(), fullScreen = NSButton()
    private let progress = NSProgressIndicator()
    private let errorText = NSTextField(labelWithString: "")
    private let retry = NSButton(title: "Retry", target: nil, action: nil)
    private let errorRow = NSStackView()
    private var observations: [NSKeyValueObservation] = []
    private var lastPreview: NSImage?
    private var lastPreviewAt: TimeInterval = 0
    /// Monotonic system-uptime seconds of the last successful new capture, never a cache hit or
    /// timeout fallback. The coordinator can preserve honest cached-image age.
    private(set) var lastPreviewSampleTime: TimeInterval?
    private var previewInFlight = false
    private var previewID: UUID?
    private var previewWaiters: [(NSImage?) -> Void] = []
    private var stopped = false
    private var navigationGeneration: UInt64 = 0
    private var blockedNavigationMessage: String?
    private var snapshotRequests = 0
#if BROWSER_HARNESS
    var testingSnapshotRequests: Int { snapshotRequests }
    var testingPreviewInFlight: Bool { previewInFlight }
#endif

    init(screen: BrowserScreen, loadImmediately: Bool = true, dataStore: WKWebsiteDataStore = .default()) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: .zero)
        identifier = .init("browserScreenPane")
        webView.identifier = .init("browserWebView")
        webView.navigationDelegate = self; webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        buildUI()
        for keyPath in [\WKWebView.canGoBack, \WKWebView.canGoForward, \WKWebView.isLoading] {
            observations.append(webView.observe(keyPath, options: [.initial,.new]) { [weak self] _,_ in
                DispatchQueue.main.async { self?.updateControls() }
            })
        }
        observations.append(webView.observe(\.title, options: [.new]) { [weak self] _,_ in
            DispatchQueue.main.async { self?.publishNavigation() }
        })
        if loadImmediately {
            do { load(try BrowserScreenStore.sanitizedURL(screen.url)) }
            catch { showError(error.localizedDescription) }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        let pending = previewWaiters
        if !pending.isEmpty { DispatchQueue.main.async { pending.forEach { $0(nil) } } }
    }

    private func buildUI() {
        func configure(_ button: NSButton, symbol: String, label: String, id: String, action: Selector) {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.bezelStyle = .texturedRounded; button.controlSize = .small
            button.toolTip = label; button.setAccessibilityLabel(label)
            button.identifier = .init(id); button.target = self; button.action = action
            button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        }
        configure(sidebar,symbol:"sidebar.left",label:"Hide connection sidebar",id:"browserSidebarToggle",action:#selector(toggleSidebar))
        configure(back,symbol:"chevron.left",label:"Back",id:"browserBack",action:#selector(goBack))
        configure(forward,symbol:"chevron.right",label:"Forward",id:"browserForward",action:#selector(goForward))
        configure(reload,symbol:"arrow.clockwise",label:"Reload website",id:"browserReload",action:#selector(reloadPage))
        configure(fullScreen,symbol:"arrow.up.left.and.arrow.down.right",label:"Full screen",id:"browserFullScreen",action:#selector(toggleFullScreen))
        address.identifier = .init("browserAddress"); address.placeholderString = "Website address"
        address.font = .systemFont(ofSize: 13); address.lineBreakMode = .byTruncatingMiddle
        address.setAccessibilityLabel("Website address"); address.target = self; address.action = #selector(navigateAddress)
        address.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        address.widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        progress.style = .spinning; progress.controlSize = .small; progress.isDisplayedWhenStopped = false
        progress.widthAnchor.constraint(equalToConstant: 16).isActive = true
        let toolbar = NSStackView(views:[sidebar,back,forward,reload,address,progress,fullScreen])
        toolbar.spacing = 6; toolbar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toolbar)
        webView.translatesAutoresizingMaskIntoConstraints = false; addSubview(webView)
        errorText.font = .systemFont(ofSize: 12); errorText.textColor = .secondaryLabelColor
        errorText.lineBreakMode = .byTruncatingTail; errorText.identifier = .init("browserError")
        errorText.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        retry.bezelStyle = .rounded; retry.controlSize = .small; retry.target = self; retry.action = #selector(retryPage)
        retry.identifier = .init("browserRetry")
        errorRow.setViews([errorText,retry],in:.center); errorRow.spacing = 8
        errorRow.translatesAutoresizingMaskIntoConstraints = false; errorRow.isHidden = true; addSubview(errorRow)
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo:leadingAnchor,constant:10), toolbar.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-10),
            toolbar.topAnchor.constraint(equalTo:topAnchor,constant:9), toolbar.heightAnchor.constraint(equalToConstant:30),
            webView.leadingAnchor.constraint(equalTo:leadingAnchor), webView.trailingAnchor.constraint(equalTo:trailingAnchor),
            webView.topAnchor.constraint(equalTo:toolbar.bottomAnchor,constant:9), webView.bottomAnchor.constraint(equalTo:bottomAnchor),
            errorRow.leadingAnchor.constraint(equalTo:leadingAnchor,constant:10), errorRow.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-10),
            errorRow.bottomAnchor.constraint(equalTo:bottomAnchor,constant:-8), errorRow.heightAnchor.constraint(equalToConstant:28)
        ])
    }

    func load(_ url: URL) {
        do {
            let safe = try BrowserScreenStore.sanitizedURL(url.absoluteString)
            stopped = false;blockedNavigationMessage = nil;currentURL = safe; address.stringValue = safe.absoluteString
            clearError(); webView.load(URLRequest(url:safe))
        } catch { showError(error.localizedDescription) }
    }
    func setActive(_ active: Bool) {
        isActive = active
        if !active {
            let ownsResponder = (window?.firstResponder as? NSView).map { $0.isDescendant(of:self) } ?? false
            if ownsResponder || address.currentEditor() != nil { window?.makeFirstResponder(nil) }
        }
    }
    func focus() { if isActive { window?.makeFirstResponder(hasError ? address : webView) } }
    func stop() {
        stopped = true;setActive(false);webView.stopLoading()
        previewID = nil;let callbacks = previewWaiters;previewWaiters = []
        callbacks.forEach { $0(nil) }
        // A pending WebKit request remains counted until it actually returns.
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard isActive,flags.contains(.command),!flags.contains(.control),!flags.contains(.option) else { return super.performKeyEquivalent(with:event) }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "l": window?.makeFirstResponder(address);address.selectText(nil);return true
        case "r": reloadPage();return true
        case "[": if webView.canGoBack { goBack() };return true
        case "]": if webView.canGoForward { goForward() };return true
        default: return super.performKeyEquivalent(with:event)
        }
    }
    func setSidebarVisible(_ visible: Bool) {
        sidebar.toolTip = visible ? "Hide connection sidebar" : "Show connection sidebar"
        sidebar.setAccessibilityLabel(sidebar.toolTip); sidebar.state = visible ? .on : .off
    }
    @objc private func toggleSidebar() { onToggleSidebar?() }
    @objc private func toggleFullScreen() { onFullScreen?() }
    @objc private func navigateAddress() {
        do { load(try BrowserScreenStore.sanitizedURL(address.stringValue)); focus() }
        catch { showError(error.localizedDescription) }
    }
    @objc private func goBack() { clearError(); webView.goBack(); focus() }
    @objc private func goForward() { clearError(); webView.goForward(); focus() }
    @objc private func reloadPage() { clearError(); webView.reload(); focus() }
    @objc private func retryPage() {
        if let url = currentURL { load(url) }
    }
    private func updateControls() {
        back.isEnabled = webView.canGoBack; forward.isEnabled = webView.canGoForward
        if webView.isLoading { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        onStateChanged?()
    }
    private func clearError() { hasError = false; errorRow.isHidden = true; errorText.stringValue = "" }
    private func showError(_ message: String) {
        hasError = true; errorText.stringValue = String(message.prefix(400)); errorText.toolTip = errorText.stringValue
        errorRow.isHidden = false; progress.stopAnimation(nil); onStateChanged?()
    }
    private func publishNavigation() {
        guard let actual = webView.url, let safe = try? BrowserScreenStore.sanitizedURL(actual.absoluteString) else { return }
        currentURL = safe
        if address.currentEditor() == nil { address.stringValue = safe.absoluteString }
        let title = webView.title.map { String($0.components(separatedBy:.controlCharacters).joined(separator:" ").prefix(160)) }
        onNavigation?(safe,title)
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        navigationGeneration &+= 1;lastPreview = nil;lastPreviewAt = 0;lastPreviewSampleTime = nil
        blockedNavigationMessage = nil;clearError(); updateControls()
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { publishNavigation(); updateControls() }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let message=blockedNavigationMessage { showError(message) } else { clearError() }
        publishNavigation();updateControls()
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { navigationFailed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { navigationFailed(error) }
    private func navigationFailed(_ error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        showError("Couldn’t load this website. Check the address or connection, then retry.")
        updateControls()
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        showError("This website stopped responding. Retry to reload it.")
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        // Internal blank child frames are part of ordinary interactive pages.
        if url.absoluteString == "about:blank" && navigationAction.targetFrame?.isMainFrame == false { decisionHandler(.allow); return }
        guard (try? BrowserScreenStore.sanitizedURL(url.absoluteString)) != nil else {
            if navigationAction.targetFrame?.isMainFrame != false { showError("This link uses an unsupported address. HTTP and HTTPS links stay in Lantern.") }
            decisionHandler(.cancel);return
        }
        if navigationAction.navigationType == .linkActivated && navigationAction.targetFrame != nil &&
            (navigationAction.modifierFlags.contains(.command) || navigationAction.buttonNumber == 2) {
            if let callback=onOpenURL { callback(url) } else { load(url) }
            decisionHandler(.cancel);return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let response=navigationResponse.response as? HTTPURLResponse,[401,407].contains(response.statusCode) {
            let message="Website authentication dialogs are disabled."
            blockedNavigationMessage=message;showError(message);decisionHandler(.cancel);return
        }
        guard navigationResponse.canShowMIMEType else { showError("This link is a download, which is not supported in browser screens yet.");decisionHandler(.cancel);return }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let raw = navigationAction.request.url, let url = try? BrowserScreenStore.sanitizedURL(raw.absoluteString) else { return nil }
        if let callback = onOpenURL { callback(url) } else { load(url) }
        return nil
    }
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling,nil)
        } else {
            let message="Website authentication dialogs are disabled."
            blockedNavigationMessage=message;showError(message)
            completionHandler(.cancelAuthenticationChallenge,nil)
        }
    }
    // These are website dialogs only; never OS authentication, credential
    // imports, client-certificate selection or trust exceptions.
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        guard isActive,let parent=window,parent.isKeyWindow,parent.attachedSheet == nil else { completionHandler(nil);return }
        let alert=NSAlert();alert.messageText="Website input";alert.informativeText=String(prompt.prefix(500))
        let field=NSTextField(string:String((defaultText ?? "").prefix(4000)));field.frame=NSRect(x:0,y:0,width:300,height:26)
        alert.accessoryView=field;alert.addButton(withTitle:"Continue");alert.addButton(withTitle:"Cancel")
        alert.beginSheetModal(for:parent) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard isActive,let parent=window,parent.isKeyWindow,parent.attachedSheet == nil else { completionHandler();return }
        let alert=NSAlert();alert.messageText="Website message";alert.informativeText=String(message.prefix(500))
        alert.addButton(withTitle:"OK");alert.beginSheetModal(for:parent) { _ in completionHandler() }
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard isActive,let parent=window,parent.isKeyWindow,parent.attachedSheet == nil else { completionHandler(false);return }
        let alert=NSAlert();alert.messageText="Website confirmation";alert.informativeText=String(message.prefix(500))
        alert.addButton(withTitle:"Continue");alert.addButton(withTitle:"Cancel")
        alert.beginSheetModal(for:parent) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    /// One WebKit snapshot at a time, at most about once per second. Completion
    /// always runs on main and is bounded even if WebKit never responds.
    func takePreview(completion: @escaping (NSImage?) -> Void) {
        guard Thread.isMainThread else { DispatchQueue.main.async { [weak self] in self?.takePreview(completion:completion) ?? completion(nil) };return }
        guard !stopped else { completion(nil);return }
        if ProcessInfo.processInfo.systemUptime-lastPreviewAt < 0.8,let image=lastPreview { completion(image);return }
        if previewInFlight {
            if previewID != nil && previewWaiters.count < 4 { previewWaiters.append(completion) }
            else { completion(lastPreview) }
            return
        }
        guard webView.bounds.width > 1,webView.bounds.height > 1 else { completion(nil);return }
        previewInFlight=true;let id=UUID();let generation=navigationGeneration;previewID=id;previewWaiters=[completion]
        let configuration=WKSnapshotConfiguration();configuration.rect=webView.bounds
        configuration.snapshotWidth=256;configuration.afterScreenUpdates=true
        snapshotRequests += 1
        DispatchQueue.main.asyncAfter(deadline:.now()+3) { [weak self] in
            guard let self=self,self.previewID == id else { return }
            self.previewID=nil;let callbacks=self.previewWaiters;self.previewWaiters=[]
            callbacks.forEach { $0(self.lastPreview) }
            // Keep in-flight true until WebKit replies: repeated timeouts must
            // not create an unbounded backlog inside its web process.
        }
        webView.takeSnapshot(with:configuration) { [weak self] image,_ in
            DispatchQueue.main.async {
                guard let self=self else { return }
                self.previewInFlight=false;self.previewID=nil
                if !self.stopped,self.navigationGeneration == generation,let image=image,let bounded=self.boundedPreview(image) {
                    self.lastPreview=bounded;self.lastPreviewAt=ProcessInfo.processInfo.systemUptime
                    self.lastPreviewSampleTime=self.lastPreviewAt
                }
                let callbacks=self.previewWaiters;self.previewWaiters=[]
                callbacks.forEach { $0(self.lastPreview) }
            }
        }
    }
    private func boundedPreview(_ image: NSImage) -> NSImage? {
        guard let source=image.cgImage(forProposedRect:nil,context:nil,hints:nil),source.width > 0,source.height > 0 else { return nil }
        let scale=min(1,min(256/Double(source.width),160/Double(source.height)))
        let width=max(1,Int(Double(source.width)*scale)),height=max(1,Int(Double(source.height)*scale))
        guard let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
                                   space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium;context.draw(source,in:CGRect(x:0,y:0,width:width,height:height))
        guard let scaled=context.makeImage() else { return nil }
        return NSImage(cgImage:scaled,size:NSSize(width:width,height:height))
    }
}
