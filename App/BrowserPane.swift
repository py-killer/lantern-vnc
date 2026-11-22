// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import WebKit

private final class BrowserTabChip: NSView {
    let select = NSButton(title:"",target:nil,action:nil)
    let close = NSButton()
    var onSelect:(()->Void)?,onClose:(()->Void)?
    init(tab:BrowserTab,selected:Bool) {
        super.init(frame:.zero)
        select.bezelStyle = .texturedRounded;select.controlSize = .small;select.setButtonType(.toggle)
        select.title=String(tab.title.prefix(28));select.toolTip=tab.title;select.state=selected ? .on : .off
        select.identifier = .init("browserTab:"+tab.id);select.setAccessibilityLabel("Select tab "+tab.title)
        select.target=self;select.action=#selector(choose)
        select.cell?.lineBreakMode = .byTruncatingTail
        close.image=NSImage(systemSymbolName:"xmark",accessibilityDescription:"Close tab")
        close.bezelStyle = .texturedRounded;close.controlSize = .small;close.toolTip="Close tab "+tab.title
        close.identifier = .init("browserCloseTab:"+tab.id);close.setAccessibilityLabel(close.toolTip)
        close.target=self;close.action=#selector(remove)
        let row=NSStackView(views:[select,close]);row.spacing=2;row.translatesAutoresizingMaskIntoConstraints=false;addSubview(row)
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo:leadingAnchor),row.trailingAnchor.constraint(equalTo:trailingAnchor),
            row.topAnchor.constraint(equalTo:topAnchor),row.bottomAnchor.constraint(equalTo:bottomAnchor),
            widthAnchor.constraint(equalToConstant:180),close.widthAnchor.constraint(equalToConstant:24)])
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func choose() { onSelect?() }
    @objc private func remove() { onClose?() }
}

/// One browser window with retained, independently navigable tabs. Unvisited
/// tabs remain metadata-only until selected; popup children are created when
/// WebKit needs them to preserve opener/message relationships.
final class BrowserScreenPane: NSView, WKNavigationDelegate, WKUIDelegate {
    var onNavigation:((URL,String?)->Void)?
    var onTabsChanged:(([BrowserTab],String)->Void)?
    var onOpenURL:((URL)->Void)? // Compatibility only; popup URLs now stay in this window.
    var onToggleSidebar:(()->Void)?,onFullScreen:(()->Void)?,onStateChanged:(()->Void)?
    private(set) var tabs:[BrowserTab]
    private(set) var selectedTabID:String
    private(set) var isActive=false
    var webView:WKWebView { ensureWebView(id:selectedTabID,loadIfNeeded:false) }
    var currentURL:URL? { tabs.first(where:{$0.id == selectedTabID}).flatMap { try? BrowserScreenStore.sanitizedURL($0.url) } }
    var hasError:Bool { states[selectedTabID]?.message != nil }
    /// System-uptime seconds of a successful NEW selected-tab capture only.
    private(set) var lastPreviewSampleTime:TimeInterval?
    private final class TabState {
        var webView:WKWebView?
        var observations:[NSKeyValueObservation]=[]
        var needsInitialLoad=true
        // Keep a provisional/failed destination independent of WKWebView.url,
        // which can still report the previous committed page after a failure.
        var pendingURL:String?
        var message:String?
        var blockedMessage:String?
    }
    private let dataStore:WKWebsiteDataStore
    private var states:[String:TabState]=[:]
    private let content=NSView(),tabDocument=NSView(),tabScroll=NSScrollView(),tabStrip=NSStackView()
    private let newTab=NSButton(),address=NSTextField(),back=NSButton(),forward=NSButton(),reload=NSButton()
    private let sidebar=NSButton(),fullScreen=NSButton(),progress=NSProgressIndicator()
    private let errorText=NSTextField(labelWithString:""),retry=NSButton(title:"Retry",target:nil,action:nil)
    private let errorRow=NSStackView(),blank=NSStackView()
    private var tabsNotificationQueued=false
    private var stopped=false
    private var previewGeneration:UInt64=0
    private var lastPreview:NSImage?,lastPreviewAt:TimeInterval=0
    private var previewInFlight=false,previewID:UUID?
    private var previewWaiters:[(NSImage?)->Void]=[]
    private var snapshotRequests=0
#if BROWSER_HARNESS
    var testingSnapshotRequests:Int { snapshotRequests }
    var testingPreviewInFlight:Bool { previewInFlight }
    var testingLoadedTabCount:Int { states.values.filter{$0.webView != nil}.count }
#endif

    init(screen:BrowserScreen,loadImmediately:Bool=true,dataStore:WKWebsiteDataStore = .default()) {
        let initial=screen.tabs.isEmpty ? [BrowserTab(id:UUID().uuidString,title:"New tab",url:"")] : screen.tabs
        tabs=initial;selectedTabID=initial.contains(where:{$0.id == screen.selectedTabID}) ? screen.selectedTabID : initial[0].id
        self.dataStore=dataStore
        super.init(frame:.zero)
        for tab in tabs { states[tab.id]=TabState() }
        identifier = .init("browserScreenPane");buildUI();rebuildTabs()
        activateSelected(loadIfNeeded:loadImmediately)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        let pending=previewWaiters
        if !pending.isEmpty { DispatchQueue.main.async { pending.forEach{$0(nil)} } }
    }
    private func buildUI() {
        func configure(_ button:NSButton,_ symbol:String,_ label:String,_ id:String,_ action:Selector) {
            button.image=NSImage(systemSymbolName:symbol,accessibilityDescription:label)
            button.bezelStyle = .texturedRounded;button.controlSize = .small;button.toolTip=label
            button.setAccessibilityLabel(label);button.identifier = .init(id);button.target=self;button.action=action
            button.widthAnchor.constraint(equalToConstant:28).isActive=true
        }
        configure(sidebar,"sidebar.left","Hide connection sidebar","browserSidebarToggle",#selector(toggleSidebar))
        configure(back,"chevron.left","Back","browserBack",#selector(goBack))
        configure(forward,"chevron.right","Forward","browserForward",#selector(goForward))
        configure(reload,"arrow.clockwise","Reload website","browserReload",#selector(reloadOrStopPage))
        configure(fullScreen,"arrow.up.left.and.arrow.down.right","Full screen","browserFullScreen",#selector(toggleFullScreen))
        configure(newTab,"plus","New tab (Command–T)","browserNewTab",#selector(addBlankTab))
        address.identifier = .init("browserAddress");address.placeholderString="Website address"
        address.font = .systemFont(ofSize:13);address.lineBreakMode = .byTruncatingMiddle
        address.setAccessibilityLabel("Website address");address.target=self;address.action=#selector(navigateAddress)
        address.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        address.widthAnchor.constraint(greaterThanOrEqualToConstant:100).isActive=true
        progress.style = .spinning;progress.controlSize = .small;progress.isDisplayedWhenStopped=false
        progress.widthAnchor.constraint(equalToConstant:16).isActive=true
        let toolbar=NSStackView(views:[sidebar,back,forward,reload,address,progress,fullScreen])
        toolbar.spacing=6;toolbar.translatesAutoresizingMaskIntoConstraints=false;addSubview(toolbar)
        tabScroll.translatesAutoresizingMaskIntoConstraints=false;tabScroll.drawsBackground=false
        tabScroll.hasHorizontalScroller=true;tabScroll.hasVerticalScroller=false;tabScroll.autohidesScrollers=true;tabScroll.scrollerStyle = .overlay
        tabDocument.translatesAutoresizingMaskIntoConstraints=false;tabScroll.documentView=tabDocument
        tabStrip.orientation = .horizontal;tabStrip.spacing=5;tabStrip.translatesAutoresizingMaskIntoConstraints=false;tabDocument.addSubview(tabStrip)
        newTab.translatesAutoresizingMaskIntoConstraints=false;addSubview(tabScroll);addSubview(newTab)
        content.translatesAutoresizingMaskIntoConstraints=false;content.wantsLayer=true
        content.layer?.backgroundColor=NSColor.windowBackgroundColor.cgColor;addSubview(content)
        let heading=NSTextField(labelWithString:"New tab");heading.font = .systemFont(ofSize:23,weight:.medium)
        let hint=NSTextField(labelWithString:"Use the address field to open a website.");hint.textColor = .secondaryLabelColor
        blank.setViews([heading,hint],in:.center);blank.orientation = .vertical;blank.spacing=10
        blank.translatesAutoresizingMaskIntoConstraints=false;content.addSubview(blank)
        errorText.font = .systemFont(ofSize:12);errorText.textColor = .secondaryLabelColor
        errorText.lineBreakMode = .byTruncatingTail;errorText.identifier = .init("browserError")
        errorText.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        retry.bezelStyle = .rounded;retry.controlSize = .small;retry.target=self;retry.action=#selector(retryPage);retry.identifier = .init("browserRetry")
        errorRow.setViews([errorText,retry],in:.center);errorRow.spacing=8;errorRow.translatesAutoresizingMaskIntoConstraints=false
        errorRow.isHidden=true;addSubview(errorRow)
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo:leadingAnchor,constant:10),toolbar.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-10),
            toolbar.topAnchor.constraint(equalTo:topAnchor,constant:9),toolbar.heightAnchor.constraint(equalToConstant:30),
            tabScroll.leadingAnchor.constraint(equalTo:leadingAnchor,constant:10),tabScroll.trailingAnchor.constraint(equalTo:newTab.leadingAnchor,constant:-6),
            tabScroll.topAnchor.constraint(equalTo:toolbar.bottomAnchor,constant:5),tabScroll.heightAnchor.constraint(equalToConstant:32),
            newTab.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-10),newTab.centerYAnchor.constraint(equalTo:tabScroll.centerYAnchor),
            tabDocument.heightAnchor.constraint(equalTo:tabScroll.contentView.heightAnchor),tabDocument.widthAnchor.constraint(greaterThanOrEqualTo:tabScroll.contentView.widthAnchor),
            tabStrip.leadingAnchor.constraint(equalTo:tabDocument.leadingAnchor),tabStrip.trailingAnchor.constraint(equalTo:tabDocument.trailingAnchor),
            tabStrip.topAnchor.constraint(equalTo:tabDocument.topAnchor),tabStrip.bottomAnchor.constraint(equalTo:tabDocument.bottomAnchor),
            content.leadingAnchor.constraint(equalTo:leadingAnchor),content.trailingAnchor.constraint(equalTo:trailingAnchor),
            content.topAnchor.constraint(equalTo:tabScroll.bottomAnchor,constant:4),content.bottomAnchor.constraint(equalTo:bottomAnchor),
            blank.centerXAnchor.constraint(equalTo:content.centerXAnchor),blank.centerYAnchor.constraint(equalTo:content.centerYAnchor),
            errorRow.leadingAnchor.constraint(equalTo:leadingAnchor,constant:10),errorRow.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-10),
            errorRow.bottomAnchor.constraint(equalTo:bottomAnchor,constant:-8),errorRow.heightAnchor.constraint(equalToConstant:28)])
    }
    private func stateID(for view:WKWebView)->String? { states.first(where:{$0.value.webView === view})?.key }
    private func ensureWebView(id:String,loadIfNeeded:Bool,configuration:WKWebViewConfiguration?=nil)->WKWebView {
        let state=states[id] ?? TabState();states[id]=state
        let view:WKWebView
        if let existing=state.webView { view=existing }
        else {
            let config=configuration ?? WKWebViewConfiguration()
            if configuration == nil { config.websiteDataStore=dataStore }
            view=WKWebView(frame:.zero,configuration:config);state.webView=view
            view.identifier = .init("browserWebView:"+id);view.navigationDelegate=self;view.uiDelegate=self
            view.allowsBackForwardNavigationGestures=true;view.translatesAutoresizingMaskIntoConstraints=false;content.addSubview(view)
            NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo:content.leadingAnchor),view.trailingAnchor.constraint(equalTo:content.trailingAnchor),
                view.topAnchor.constraint(equalTo:content.topAnchor),view.bottomAnchor.constraint(equalTo:content.bottomAnchor)])
            view.isHidden=true
            for keyPath in [\WKWebView.canGoBack,\WKWebView.canGoForward,\WKWebView.isLoading] {
                state.observations.append(view.observe(keyPath,options:[.initial,.new]) { [weak self] _,_ in
                    DispatchQueue.main.async { self?.updateControls() }
                })
            }
            state.observations.append(view.observe(\.title,options:[.new]) { [weak self,weak view] _,_ in
                DispatchQueue.main.async { if let view=view { self?.publishNavigation(for:view) } }
            })
            state.observations.append(view.observe(\.url,options:[.new]) { [weak self,weak view] _,_ in
                DispatchQueue.main.async { if let view=view { self?.publishNavigation(for:view) } }
            })
        }
        if loadIfNeeded,state.needsInitialLoad,let tab=tabs.first(where:{$0.id == id}),!tab.url.isEmpty,
           let url=try? BrowserScreenStore.sanitizedURL(tab.url) {
            state.needsInitialLoad=false;state.pendingURL=url.absoluteString;view.load(URLRequest(url:url))
        }
        return view
    }
    private func activateSelected(loadIfNeeded:Bool=true) {
        let selected=ensureWebView(id:selectedTabID,loadIfNeeded:loadIfNeeded)
        let empty=tabs.first(where:{$0.id == selectedTabID})?.url.isEmpty ?? true
        for (id,state) in states { state.webView?.isHidden=id != selectedTabID || empty }
        blank.isHidden = !empty
        if empty { content.addSubview(blank,positioned:.above,relativeTo:selected) }
        address.stringValue=tabs.first(where:{$0.id == selectedTabID})?.url ?? ""
        rebuildTabs();updateControls()
    }
    private func rebuildTabs() {
        let chips=tabs.map { tab -> NSView in
            let chip=BrowserTabChip(tab:tab,selected:tab.id == selectedTabID)
            chip.onSelect={ [weak self] in self?.selectTab(id:tab.id) }
            chip.onClose={ [weak self] in self?.closeTab(id:tab.id) }
            return chip
        }
        tabStrip.setViews(chips,in:.center);newTab.isEnabled=tabs.count < BrowserScreenStore.maximumTabsPerScreen
        if let index=tabs.firstIndex(where:{$0.id == selectedTabID}),chips.indices.contains(index) { _=chips[index].scrollToVisible(chips[index].bounds) }
    }
    private func notifyTabsChanged() {
        guard !tabsNotificationQueued else { return };tabsNotificationQueued=true
        DispatchQueue.main.async { [weak self] in
            guard let self=self else { return };self.tabsNotificationQueued=false
            self.onTabsChanged?(self.tabs,self.selectedTabID)
        }
    }
    private func resetPreview() { previewGeneration &+= 1;lastPreview=nil;lastPreviewAt=0;lastPreviewSampleTime=nil }
    @discardableResult
    func addTab(url:URL?=nil,select:Bool=true)->String? { appendTab(url:url,select:select,configuration:nil,webKitWillLoad:false) }
    private func appendTab(url:URL?,select:Bool,configuration:WKWebViewConfiguration?,webKitWillLoad:Bool)->String? {
        guard tabs.count < BrowserScreenStore.maximumTabsPerScreen else { showError("This browser window already has 12 tabs.",id:selectedTabID);return nil }
        let safe:URL?
        if let url=url { guard let validated=try? BrowserScreenStore.sanitizedURL(url.absoluteString) else { return nil };safe=validated } else { safe=nil }
        let id=UUID().uuidString;tabs.append(BrowserTab(id:id,title:safe?.host ?? "New tab",url:safe?.absoluteString ?? ""));states[id]=TabState()
        if let configuration=configuration {
            _=ensureWebView(id:id,loadIfNeeded:false,configuration:configuration);states[id]?.needsInitialLoad = !webKitWillLoad
        }
        if select { selectTab(id:id) } else { rebuildTabs();notifyTabsChanged() }
        return id
    }
    func selectTab(id:String) {
        guard tabs.contains(where:{$0.id == id}) else { return }
        if selectedTabID != id { window?.endEditing(for:address);selectedTabID=id;resetPreview() }
        activateSelected();notifyTabsChanged();focus()
    }
    func closeTab(id:String) {
        guard let index=tabs.firstIndex(where:{$0.id == id}) else { return }
        states[id]?.webView?.stopLoading();states[id]?.webView?.removeFromSuperview();states.removeValue(forKey:id);tabs.remove(at:index)
        if tabs.isEmpty {
            let blankTab=BrowserTab(id:UUID().uuidString,title:"New tab",url:"");tabs=[blankTab];states[blankTab.id]=TabState();selectedTabID=blankTab.id;resetPreview()
        } else if selectedTabID == id { selectedTabID=tabs[min(index,tabs.count-1)].id;resetPreview() }
        activateSelected();notifyTabsChanged();focus()
    }
    private func cycleTab(_ step:Int) {
        guard let index=tabs.firstIndex(where:{$0.id == selectedTabID}),!tabs.isEmpty else { return }
        selectTab(id:tabs[(index+step+tabs.count)%tabs.count].id)
    }
    func load(_ url:URL) {
        do {
            let safe=try BrowserScreenStore.sanitizedURL(url.absoluteString)
            guard let index=tabs.firstIndex(where:{$0.id == selectedTabID}) else { return }
            stopped=false;tabs[index].url=safe.absoluteString
            let state=states[selectedTabID]!;state.needsInitialLoad=false;state.pendingURL=safe.absoluteString;state.blockedMessage=nil;state.message=nil
            blank.isHidden=true;let view=ensureWebView(id:selectedTabID,loadIfNeeded:false);view.isHidden=false
            address.stringValue=safe.absoluteString;resetPreview();notifyTabsChanged();updateControls();view.load(URLRequest(url:safe))
        } catch { showError(error.localizedDescription,id:selectedTabID) }
    }
    func setActive(_ active:Bool) {
        isActive=active
        if !active {
            let owns=(window?.firstResponder as? NSView).map{$0.isDescendant(of:self)} ?? false
            if owns || address.currentEditor() != nil { window?.makeFirstResponder(nil) }
        }
    }
    func focus() { if isActive { window?.makeFirstResponder(hasError || currentURL == nil ? address : webView) } }
    func stop() {
        stopped=true;setActive(false);states.values.forEach{$0.webView?.stopLoading()}
        previewID=nil;let callbacks=previewWaiters;previewWaiters=[];callbacks.forEach{$0(nil)}
    }
    func setSidebarVisible(_ visible:Bool) {
        sidebar.toolTip=visible ? "Hide connection sidebar" : "Show connection sidebar";sidebar.setAccessibilityLabel(sidebar.toolTip);sidebar.state=visible ? .on : .off
    }
    override func performKeyEquivalent(with event:NSEvent)->Bool {
        guard isActive else { return super.performKeyEquivalent(with:event) }
        let flags=event.modifierFlags.intersection(.deviceIndependentFlagsMask),key=event.charactersIgnoringModifiers?.lowercased()
        if flags.contains(.control),!flags.contains(.command),event.keyCode == 48 { cycleTab(flags.contains(.shift) ? -1 : 1);return true }
        guard flags.contains(.command),!flags.contains(.control),!flags.contains(.option) else { return super.performKeyEquivalent(with:event) }
        switch key {
        case "l": window?.makeFirstResponder(address);address.selectText(nil);return true
        case "t" where !flags.contains(.shift): _=addTab();return true
        case "w" where !flags.contains(.shift): closeTab(id:selectedTabID);return true
        case "r": reloadPage();return true
        case "[": if flags.contains(.shift) { cycleTab(-1) } else if webView.canGoBack { goBack() };return true
        case "]": if flags.contains(.shift) { cycleTab(1) } else if webView.canGoForward { goForward() };return true
        case "{" where flags.contains(.shift): cycleTab(-1);return true
        case "}" where flags.contains(.shift): cycleTab(1);return true
        default: return super.performKeyEquivalent(with:event)
        }
    }
    @objc private func toggleSidebar() { onToggleSidebar?() }
    @objc private func toggleFullScreen() { onFullScreen?() }
    @objc private func addBlankTab() { _=addTab() }
    @objc private func navigateAddress() { do { load(try BrowserScreenStore.sanitizedURL(address.stringValue));focus() } catch { showError(error.localizedDescription,id:selectedTabID) } }
    @objc private func goBack() { states[selectedTabID]?.message=nil;webView.goBack();focus() }
    @objc private func goForward() { states[selectedTabID]?.message=nil;webView.goForward();focus() }
    @objc private func reloadOrStopPage() {
        guard let view=states[selectedTabID]?.webView,view.isLoading else { reloadPage();return }
        // Keep the intended address when stopping a provisional navigation:
        // WebKit may restore its previous committed URL during cancellation.
        states[selectedTabID]?.pendingURL=currentURL?.absoluteString
        states[selectedTabID]?.message=nil;states[selectedTabID]?.blockedMessage=nil
        view.stopLoading();updateControls();focus()
    }
    @objc private func reloadPage() {
        guard let url=currentURL else { focus();return }
        states[selectedTabID]?.message=nil
        let view=webView
        if view.url == url,view.backForwardList.currentItem?.url == url { view.reload() }
        else { load(url) }
        updateControls();focus()
    }
    @objc private func retryPage() { if let url=currentURL { load(url) } }
    private func updateControls() {
        let view=states[selectedTabID]?.webView
        back.isEnabled=view?.canGoBack ?? false;forward.isEnabled=view?.canGoForward ?? false
        let loading=view?.isLoading == true
        if loading { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        let reloadLabel=loading ? "Stop loading website" : "Reload website"
        if reload.toolTip != reloadLabel {
            reload.image=NSImage(systemSymbolName:loading ? "xmark" : "arrow.clockwise",accessibilityDescription:reloadLabel)
            reload.toolTip=reloadLabel;reload.setAccessibilityLabel(reloadLabel)
        }
        reload.isEnabled=loading || currentURL != nil
        let message=states[selectedTabID]?.message;errorRow.isHidden=message == nil;errorText.stringValue=message ?? "";errorText.toolTip=message
        onStateChanged?()
    }
    private func showError(_ message:String,id:String) { states[id]?.message=String(message.prefix(400));if id == selectedTabID { updateControls() } }
    private func publishNavigation(for view:WKWebView) {
        guard let id=stateID(for:view),let index=tabs.firstIndex(where:{$0.id == id}),
              let raw=view.url,let safe=try? BrowserScreenStore.sanitizedURL(raw.absoluteString) else { return }
        if let pending=states[id]?.pendingURL,pending != safe.absoluteString { return }
        let title=String((view.title ?? safe.host ?? "Web page").components(separatedBy:.controlCharacters).joined(separator:" ").prefix(80))
        let changed=tabs[index].url != safe.absoluteString || tabs[index].title != title
        tabs[index].url=safe.absoluteString;tabs[index].title=title.isEmpty ? safe.host ?? "Web page" : title
        if changed { rebuildTabs();notifyTabsChanged() }
        if id == selectedTabID {
            blank.isHidden=true;view.isHidden=false
            if address.currentEditor() == nil { address.stringValue=safe.absoluteString }
            onNavigation?(safe,tabs[index].title)
        }
    }
    func webView(_ webView:WKWebView,didStartProvisionalNavigation navigation:WKNavigation!) {
        guard let id=stateID(for:webView) else { return };states[id]?.message=nil;states[id]?.blockedMessage=nil
        if id == selectedTabID { resetPreview() };updateControls()
    }
    func webView(_ webView:WKWebView,didCommit navigation:WKNavigation!) {
        if let id=stateID(for:webView) { states[id]?.pendingURL=nil }
        publishNavigation(for:webView);updateControls()
    }
    func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!) {
        if let id=stateID(for:webView) { states[id]?.message=states[id]?.blockedMessage }
        publishNavigation(for:webView);updateControls()
    }
    func webView(_ webView:WKWebView,didFail navigation:WKNavigation!,withError error:Error) { navigationFailed(error,view:webView) }
    func webView(_ webView:WKWebView,didFailProvisionalNavigation navigation:WKNavigation!,withError error:Error) { navigationFailed(error,view:webView) }
    private func navigationFailed(_ error:Error,view:WKWebView) {
        let failure=error as NSError
        guard let id=stateID(for:view) else { return }
        if failure.domain == NSURLErrorDomain,failure.code == NSURLErrorCancelled { updateControls();return }
        showError(states[id]?.blockedMessage ?? Self.navigationErrorMessage(failure),id:id);updateControls()
    }
    /// Fixed category messages never interpolate error descriptions, URLs,
    /// query strings, server replies or credential-bearing userInfo values.
    private static func navigationErrorMessage(_ error:NSError) -> String {
        guard error.domain == NSURLErrorDomain else { return "Couldn’t load this website. Check the address or connection, then retry." }
        switch error.code {
        case NSURLErrorCannotFindHost,NSURLErrorDNSLookupFailed:
            return "Couldn’t find this website. Check the address or DNS settings."
        case NSURLErrorNotConnectedToInternet:
            return "This Mac is offline. Check your network connection, then retry."
        case NSURLErrorNetworkConnectionLost:
            return "The connection to this website was interrupted. Check your network, then retry."
        case NSURLErrorTimedOut:
            return "This website took too long to respond. Retry when the connection is available."
        case NSURLErrorCannotConnectToHost:
            return "Couldn’t connect to this website. Check the server or network, then retry."
        case NSURLErrorSecureConnectionFailed,NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateUntrusted,NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid,NSURLErrorClientCertificateRejected,
             NSURLErrorClientCertificateRequired:
            return "A secure connection couldn’t be verified. Check the website’s HTTPS certificate."
        case NSURLErrorAppTransportSecurityRequiresSecureConnection:
            return "macOS blocked this insecure connection. Use an HTTPS address."
        default:
            return "Couldn’t load this website. Check the address or connection, then retry."
        }
    }
    func webViewWebContentProcessDidTerminate(_ webView:WKWebView) { if let id=stateID(for:webView) { showError("This website stopped responding. Retry to reload it.",id:id) } }
    func webView(_ webView:WKWebView,decidePolicyFor navigationAction:WKNavigationAction,decisionHandler:@escaping(WKNavigationActionPolicy)->Void) {
        guard let url=navigationAction.request.url,let id=stateID(for:webView) else { decisionHandler(.cancel);return }
        if url.absoluteString == "about:blank",navigationAction.targetFrame?.isMainFrame == false || tabs.first(where:{$0.id == id})?.url.isEmpty == true {
            decisionHandler(.allow);return
        }
        guard let safe=try? BrowserScreenStore.sanitizedURL(url.absoluteString) else {
            if navigationAction.targetFrame?.isMainFrame != false { showError("This link uses an unsupported address. HTTP and HTTPS links stay in Lantern.",id:id) }
            decisionHandler(.cancel);return
        }
        if navigationAction.navigationType == .linkActivated,navigationAction.targetFrame != nil,
           navigationAction.modifierFlags.contains(.command) || navigationAction.buttonNumber == 2 {
            _=addTab(url:safe,select:isActive && id == selectedTabID);decisionHandler(.cancel);return
        }
        if navigationAction.targetFrame?.isMainFrame == true,let index=tabs.firstIndex(where:{$0.id == id}) {
            states[id]?.pendingURL=safe.absoluteString;tabs[index].url=safe.absoluteString;notifyTabsChanged()
        }
        decisionHandler(.allow)
    }
    func webView(_ webView:WKWebView,decidePolicyFor navigationResponse:WKNavigationResponse,decisionHandler:@escaping(WKNavigationResponsePolicy)->Void) {
        guard let id=stateID(for:webView) else { decisionHandler(.cancel);return }
        if let response=navigationResponse.response as? HTTPURLResponse,[401,407].contains(response.statusCode) {
            let message="Website authentication dialogs are disabled.";states[id]?.blockedMessage=message;showError(message,id:id);decisionHandler(.cancel);return
        }
        guard navigationResponse.canShowMIMEType else { showError("This link is a download, which is not supported in browser screens yet.",id:id);decisionHandler(.cancel);return }
        decisionHandler(.allow)
    }
    func webView(_ webView:WKWebView,createWebViewWith configuration:WKWebViewConfiguration,for navigationAction:WKNavigationAction,windowFeatures:WKWindowFeatures)->WKWebView? {
        guard let sourceID=stateID(for:webView),let raw=navigationAction.request.url else { return nil }
        let url:URL?
        if raw.absoluteString == "about:blank" { url=nil }
        else { guard let safe=try? BrowserScreenStore.sanitizedURL(raw.absoluteString) else { return nil };url=safe }
        guard let id=appendTab(url:url,select:isActive && sourceID == selectedTabID,configuration:configuration,webKitWillLoad:true) else { return nil }
        return states[id]?.webView
    }
    func webViewDidClose(_ webView:WKWebView) { if let id=stateID(for:webView) { closeTab(id:id) } }
    func webView(_ webView:WKWebView,didReceive challenge:URLAuthenticationChallenge,completionHandler:@escaping(URLSession.AuthChallengeDisposition,URLCredential?)->Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust { completionHandler(.performDefaultHandling,nil) }
        else {
            if let id=stateID(for:webView) { let message="Website authentication dialogs are disabled.";states[id]?.blockedMessage=message;showError(message,id:id) }
            completionHandler(.cancelAuthenticationChallenge,nil)
        }
    }
    private func dialogParent(for view:WKWebView)->NSWindow? {
        guard isActive,stateID(for:view) == selectedTabID,let parent=window,parent.isKeyWindow,parent.attachedSheet == nil else { return nil };return parent
    }
    func webView(_ webView:WKWebView,runJavaScriptTextInputPanelWithPrompt prompt:String,defaultText:String?,initiatedByFrame frame:WKFrameInfo,completionHandler:@escaping(String?)->Void) {
        guard let parent=dialogParent(for:webView) else { completionHandler(nil);return }
        let alert=NSAlert();alert.messageText="Website input";alert.informativeText=String(prompt.prefix(500))
        let field=NSTextField(string:String((defaultText ?? "").prefix(4000)));field.frame=NSRect(x:0,y:0,width:300,height:26)
        alert.accessoryView=field;alert.addButton(withTitle:"Continue");alert.addButton(withTitle:"Cancel")
        alert.beginSheetModal(for:parent) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }
    func webView(_ webView:WKWebView,runJavaScriptAlertPanelWithMessage message:String,initiatedByFrame frame:WKFrameInfo,completionHandler:@escaping()->Void) {
        guard let parent=dialogParent(for:webView) else { completionHandler();return }
        let alert=NSAlert();alert.messageText="Website message";alert.informativeText=String(message.prefix(500));alert.addButton(withTitle:"OK")
        alert.beginSheetModal(for:parent) { _ in completionHandler() }
    }
    func webView(_ webView:WKWebView,runJavaScriptConfirmPanelWithMessage message:String,initiatedByFrame frame:WKFrameInfo,completionHandler:@escaping(Bool)->Void) {
        guard let parent=dialogParent(for:webView) else { completionHandler(false);return }
        let alert=NSAlert();alert.messageText="Website confirmation";alert.informativeText=String(message.prefix(500));alert.addButton(withTitle:"Continue");alert.addButton(withTitle:"Cancel")
        alert.beginSheetModal(for:parent) { completionHandler($0 == .alertFirstButtonReturn) }
    }
    func takePreview(completion:@escaping(NSImage?)->Void) {
        guard Thread.isMainThread else { DispatchQueue.main.async { [weak self] in self?.takePreview(completion:completion) ?? completion(nil) };return }
        guard !stopped,currentURL != nil else { completion(nil);return }
        if ProcessInfo.processInfo.systemUptime-lastPreviewAt < 0.8,let image=lastPreview { completion(image);return }
        if previewInFlight { if previewID != nil,previewWaiters.count < 4 { previewWaiters.append(completion) } else { completion(lastPreview) };return }
        let view=webView
        guard view.bounds.width > 1,view.bounds.height > 1 else { completion(nil);return }
        previewInFlight=true;let id=UUID(),generation=previewGeneration;let tabID=selectedTabID;previewID=id;previewWaiters=[completion]
        let configuration=WKSnapshotConfiguration();configuration.rect=view.bounds;configuration.snapshotWidth=256;configuration.afterScreenUpdates=true;snapshotRequests += 1
        DispatchQueue.main.asyncAfter(deadline:.now()+3) { [weak self] in
            guard let self=self,self.previewID == id else { return };self.previewID=nil
            let callbacks=self.previewWaiters;self.previewWaiters=[];callbacks.forEach{$0(self.lastPreview)}
            // Count the underlying request until WebKit actually returns.
        }
        view.takeSnapshot(with:configuration) { [weak self] image,_ in
            DispatchQueue.main.async {
                guard let self=self else { return };self.previewInFlight=false;self.previewID=nil
                if !self.stopped,self.previewGeneration == generation,self.selectedTabID == tabID,let image=image,let bounded=self.boundedPreview(image) {
                    self.lastPreview=bounded;self.lastPreviewAt=ProcessInfo.processInfo.systemUptime;self.lastPreviewSampleTime=self.lastPreviewAt
                }
                let callbacks=self.previewWaiters;self.previewWaiters=[];callbacks.forEach{$0(self.lastPreview)}
            }
        }
    }
    private func boundedPreview(_ image:NSImage)->NSImage? {
        guard let source=image.cgImage(forProposedRect:nil,context:nil,hints:nil),source.width > 0,source.height > 0 else { return nil }
        let scale=min(1,min(256/Double(source.width),160/Double(source.height)))
        let width=max(1,Int(Double(source.width)*scale)),height=max(1,Int(Double(source.height)*scale))
        guard let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium;context.draw(source,in:CGRect(x:0,y:0,width:width,height:height))
        guard let scaled=context.makeImage() else { return nil };return NSImage(cgImage:scaled,size:NSSize(width:width,height:height))
    }
}
