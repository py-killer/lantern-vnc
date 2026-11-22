// SPDX-License-Identifier: GPL-2.0-or-later
// Owned invisible/offscreen windows, an ephemeral cookie store and synthetic
// loopback pages only. No real websites, credentials, app activation or input.
import AppKit
import WebKit
import Foundation

/// Exercises foreground dialog policy without making a real app/window key.
private final class BrowserDialogWindow: NSWindow {
    var testingForeground = false
    private(set) var invisibleSheets = 0
    override var isKeyWindow: Bool { testingForeground || super.isKeyWindow }
    override func beginSheet(_ sheetWindow: NSWindow, completionHandler handler: ((NSApplication.ModalResponse) -> Void)? = nil) {
        // AppKit can constrain a sheet onto a physical screen independently of
        // its parent's frame. Hide it before presentation, not after polling.
        sheetWindow.alphaValue=0;invisibleSheets += 1
        super.beginSheet(sheetWindow,completionHandler:handler)
    }
}

@main
struct BrowserHarness {
    private static var checks=0
    private static func expect(_ value: @autoclosure () -> Bool,_ label: String) {
        checks += 1;guard value() else { fatalError("Browser harness: \(label)") }
    }
    private static func settle(_ interval: TimeInterval=0.02) { RunLoop.current.run(until:Date(timeIntervalSinceNow:interval)) }
    private static func wait(_ label:String,timeout:TimeInterval=10,diagnostics:(()->String)?=nil,until ready:()->Bool) {
        let limit=Date(timeIntervalSinceNow:timeout)
        while !ready() && Date() < limit { settle() }
        let passed=ready()
        expect(passed,passed ? label : label+" ["+(diagnostics?() ?? "deadline expired")+"]")
    }
    private static func views(_ view:NSView)->[NSView] { [view]+view.subviews.flatMap(views) }
    private static func serverSaw(_ path:String,events:String)->Bool {
        guard let text=try? String(contentsOfFile:events,encoding:.utf8) else { return false }
        return text.split(separator:"\n").contains { line in
            guard let data=String(line).data(using:.utf8),let row=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] else { return false }
            return row["path"] as? String == path
        }
    }
    private static func find<T:NSView>(_ id:String,in pane:BrowserScreenPane,as type:T.Type)->T {
        guard let result=views(pane).first(where:{$0.identifier?.rawValue == id}) as? T else { fatalError("Missing browser control \(id)") }
        return result
    }
    private static func click(_ id:String,in pane:BrowserScreenPane) {
        let button:NSButton=find(id,in:pane,as:NSButton.self)
        expect(button.isEnabled && button.sendAction(button.action,to:button.target),"owned browser control is enabled and wired: \(id)")
    }
    private static func js(_ script:String,in pane:BrowserScreenPane)->Any? {
        js(script,in:pane.webView)
    }
    private static func js(_ script:String,in view:WKWebView)->Any? {
        var done=false,result:Any?,failure:Error?
        view.evaluateJavaScript(script) { value,error in result=value;failure=error;done=true }
        wait("owned JavaScript completes") { done }
        expect(failure == nil,"owned JavaScript executes without error")
        return result
    }
    private static func shortcut(_ key:String,code:UInt16,flags:NSEvent.ModifierFlags=[.command],pane:BrowserScreenPane,window:NSWindow)->Bool {
        let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:key,charactersIgnoringModifiers:key,isARepeat:false,keyCode:code)!
        return pane.performKeyEquivalent(with:event)
    }
    private static func domClick(_ id:String,in pane:BrowserScreenPane,window:NSWindow) {
        guard let point=js("(()=>{let r=document.getElementById('\(id)').getBoundingClientRect();return [r.x+r.width/2,r.y+r.height/2]})()",in:pane) as? [Double],point.count == 2 else { fatalError("Missing owned DOM control") }
        let local=CGPoint(x:point[0],y:pane.webView.isFlipped ? point[1] : pane.webView.bounds.height-point[1])
        let location=pane.webView.convert(local,to:nil)
        let hitPoint=pane.webView.convert(local,to:pane.webView.superview)
        let target=pane.webView.hitTest(hitPoint) ?? pane.webView
        let down=NSEvent.mouseEvent(with:.leftMouseDown,location:location,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
        let up=NSEvent.mouseEvent(with:.leftMouseUp,location:location,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:2,clickCount:1,pressure:0)!
        target.mouseDown(with:down);target.mouseUp(with:up)
    }
    private static func preview(_ pane:BrowserScreenPane)->NSImage? {
        var done=false,result:NSImage?
        pane.takePreview { image in expect(Thread.isMainThread,"preview completion runs on main");result=image;done=true }
        wait("preview completes within bounded timeout",timeout:4) { done }
        return result
    }
    private static func rgb(_ image:NSImage)->NSColor {
        let cg=image.cgImage(forProposedRect:nil,context:nil,hints:nil)!
        expect(cg.width <= 256 && cg.height <= 160,"preview has bounded pixel dimensions")
        return NSBitmapImageRep(cgImage:cg).colorAt(x:cg.width/2,y:cg.height/2)!.usingColorSpace(.deviceRGB)!
    }
    private static func foregroundDialogs(in pane:BrowserScreenPane,window:BrowserDialogWindow) {
        let activeBefore=NSApp.isActive
        let originalAlpha=window.alphaValue
        let originalSheets=window.invisibleSheets
        window.alphaValue=0
        window.testingForeground=true
        defer {
            window.testingForeground=false
            window.setFrameOrigin(NSPoint(x:-10000,y:-10000))
            window.alphaValue=originalAlpha
        }
        func answer(_ script:String,title:String,response:NSApplication.ModalResponse,input:String?=nil)->Any? {
            var completed=0,result:Any?,failure:Error?
            pane.webView.evaluateJavaScript(script) { value,error in result=value;failure=error;completed += 1 }
            wait("foreground website dialog creates an owned sheet") { window.attachedSheet != nil }
            let sheet=window.attachedSheet!
            let labels=sheet.contentView.map { views($0).compactMap { $0 as? NSTextField }.map { $0.stringValue } } ?? []
            expect(labels.contains(title),"foreground sheet belongs to the requested website dialog")
            expect(completed == 0,"JavaScript waits for the website dialog response")
            expect(sheet.alphaValue == 0 && window.alphaValue == 0,
                   "owned website sheet and parent are invisible before test responses")
            if let input=input {
                guard let field=sheet.contentView.flatMap({ views($0).compactMap { $0 as? NSTextField }.first { $0.isEditable } }) else {
                    fatalError("Missing owned website prompt field")
                }
                expect(field.stringValue == "fixture-default","website prompt displays only its synthetic default")
                field.stringValue=input
            }
            window.endSheet(sheet,returnCode:response);sheet.orderOut(nil)
            wait("foreground website dialog completes JavaScript") { completed != 0 }
            expect(completed == 1 && failure == nil,"foreground dialog completes exactly once without script error")
            expect(window.attachedSheet == nil,"foreground website sheet is detached after response")
            expect(NSApp.isActive == activeBefore,"owned website dialog never activates the app")
            return result
        }
        let alert=answer("(()=>{alert('Owned alert fixture');return 'alert-finished'})()",title:"Website message",response:.alertFirstButtonReturn)
        expect(alert as? String == "alert-finished","alert acknowledgement resumes the calling website script")
        let confirmed=answer("confirm('Owned confirmation fixture')",title:"Website confirmation",response:.alertFirstButtonReturn)
        expect(confirmed as? Bool == true,"confirmation Continue returns true to the website")
        let canceled=answer("confirm('Owned cancel fixture')",title:"Website confirmation",response:.alertSecondButtonReturn)
        expect(canceled as? Bool == false,"confirmation Cancel returns false to the website")
        let prompt=answer("prompt('Owned text fixture','fixture-default')",title:"Website input",response:.alertFirstButtonReturn,input:"owned-answer")
        expect(prompt as? String == "owned-answer","prompt returns the owned synthetic reply to the website")
        let dismissed=answer("prompt('Owned text cancellation','fixture-default')",title:"Website input",response:.alertSecondButtonReturn)
        expect(dismissed == nil || dismissed is NSNull,"canceled website prompt returns null")
        expect(window.invisibleSheets-originalSheets == 5,"all foreground dialogs were hidden before native presentation")
    }
    static func main() throws {
        guard CommandLine.arguments.count == 4,let base=URL(string:CommandLine.arguments[1]) else { exit(2) }
        let fixtureEvents=CommandLine.arguments[3]
        guard !NSScreen.screens.isEmpty else {
            fputs("NOT RUN: browser integration needs WindowServer access (exit 77).\n",stderr);exit(77)
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        let window=BrowserDialogWindow(contentRect:NSRect(x:-10000,y:-10000,width:572,height:492),styleMask:[.borderless],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.ignoresMouseEvents=true
        let host=NSView(frame:NSRect(x:0,y:0,width:572,height:492));window.contentView=host
        let dataStore=WKWebsiteDataStore.nonPersistent()
        let first=BrowserScreenPane(screen:BrowserScreen(id:UUID().uuidString,title:"Owned one",url:base.appendingPathComponent("one").absoluteString),loadImmediately:false,dataStore:dataStore)
        let second=BrowserScreenPane(screen:BrowserScreen(id:UUID().uuidString,title:"Owned two",url:base.appendingPathComponent("two").absoluteString),loadImmediately:false,dataStore:dataStore)
        for pane in [first,second] {
            pane.translatesAutoresizingMaskIntoConstraints=false;host.addSubview(pane)
            NSLayoutConstraint.activate([pane.leadingAnchor.constraint(equalTo:host.leadingAnchor),pane.trailingAnchor.constraint(equalTo:host.trailingAnchor),pane.topAnchor.constraint(equalTo:host.topAnchor),pane.bottomAnchor.constraint(equalTo:host.bottomAnchor)])
        }
        second.isHidden=true;first.setActive(true);second.setActive(false)
        window.orderBack(nil);window.setFrameOrigin(NSPoint(x:-10000,y:-10000));host.layoutSubtreeIfNeeded();settle()
        defer { first.stop();second.stop();window.delegate=nil;window.orderOut(nil);window.close() }
        expect(!window.isKeyWindow,"owned browser window never takes keyboard focus")
        expect(!dataStore.isPersistent,"owned fixtures use ephemeral cookies instead of any real browsing data")
        var navigations:[(URL,String?)]=[],opened:[URL]=[],sidebarActions=0,fullActions=0
        var savedTabs:[BrowserTab]=[],savedSelection=""
        first.onTabsChanged={ savedTabs=$0;savedSelection=$1 }
        first.onNavigation={ navigations.append(($0,$1)) };first.onOpenURL={ opened.append($0) }
        first.onToggleSidebar={ sidebarActions += 1 };first.onFullScreen={ fullActions += 1 }
        first.load(base.appendingPathComponent("one"));second.load(base.appendingPathComponent("two"))
        wait("both owned interactive pages load") { first.webView.title == "Fixture One" && second.webView.title == "Fixture Two" && !first.webView.isLoading && !second.webView.isLoading }
        expect(!first.hasError && !second.hasError,"HTTP loopback pages load without an ATS exception")
        expect(navigations.contains { $0.1 == "Fixture One" && $0.0.path == "/one" },"navigation callback contains the safe current URL and meaningful title")
        expect((js("document.cookie",in:second) as? String)?.contains("lanternFixture=shared") == true,"loaded cards share only their explicitly supplied WebKit cookie store")
        for id in ["browserSidebarToggle","browserBack","browserForward","browserReload","browserAddress","browserFullScreen","browserNewTab"] {
            let view:NSView=find(id,in:first,as:NSView.self)
            expect(view.frame.width >= 20 && first.bounds.contains(view.convert(view.bounds,to:first)),"browser toolbar control fits a572-point host: \(id)")
        }
        first.setSidebarVisible(false)
        let sidebar:NSButton=find("browserSidebarToggle",in:first,as:NSButton.self)
        expect(sidebar.toolTip == "Show connection sidebar","hidden sidebar has a visible restore control")
        click("browserSidebarToggle",in:first);click("browserFullScreen",in:first)
        expect(sidebarActions == 1 && fullActions == 1,"browser toolbar routes sidebar/fullscreen to the existing coordinator")
        first.focus();domClick("input",in:first,window:window)
        let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:"z",charactersIgnoringModifiers:"z",isARepeat:false,keyCode:6)!
        (window.firstResponder ?? first.webView).keyDown(with:event)
        wait("owned WebKit keyboard event reaches the focused form") { (js("document.getElementById('input').value",in:first) as? String)?.contains("z") == true }
        domClick("echo",in:first,window:window)
        wait("owned HTML button handles input") { (js("document.getElementById('output').textContent",in:first) as? String)?.contains("z") == true }
        _=js("document.getElementById('choice').value='two';document.getElementById('choice').dispatchEvent(new Event('change'));true",in:first)
        expect(js("window.choice",in:first) as? String == "two","website form/select events remain interactive")
        let cmdL=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[.command],timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"l",charactersIgnoringModifiers:"l",isARepeat:false,keyCode:37)!
        expect(first.performKeyEquivalent(with:cmdL),"active browser handles Command-L")
        let address:NSTextField=find("browserAddress",in:first,as:NSTextField.self)
        expect(address.currentEditor() != nil,"Command-L focuses the native address field")
        address.stringValue=base.appendingPathComponent("two").absoluteString
        expect(address.sendAction(address.action,to:address.target),"address field loads the requested URL")
        wait("address navigation reaches second page") { first.webView.title == "Fixture Two" && !first.webView.isLoading }
        click("browserBack",in:first)
        wait("native Back restores first page") { first.webView.title == "Fixture One" && !first.webView.isLoading }
        click("browserForward",in:first)
        wait("native Forward restores second page") { first.webView.title == "Fixture Two" && !first.webView.isLoading }
        let beforeReload=js("window.cardToken",in:first) as? String
        click("browserReload",in:first)
        wait("native Reload starts a new page instance") { !first.webView.isLoading && (js("window.cardToken",in:first) as? String) != beforeReload }
        click("browserBack",in:first)
        wait("return to popup fixture") { first.webView.title == "Fixture One" && !first.webView.isLoading }
        let originalTab=first.selectedTabID,originalView=first.webView
        let originalToken=js("window.cardToken",in:first) as? String
        domClick("popup",in:first,window:window)
        wait("target-blank opens a selected tab inside the existing browser window") {
            first.tabs.count == 2 && first.selectedTabID != originalTab && first.webView.title == "Fixture Popup" && !first.webView.isLoading
        }
        let popupTab=first.selectedTabID
        expect(opened.isEmpty,"popup never creates an unrelated sidebar browser window")
        first.selectTab(id:originalTab)
        expect(first.webView === originalView && first.webView.url?.path == "/one" && js("window.cardToken",in:first) as? String == originalToken,
               "switching tabs preserves the original page instance and history")
        domClick("openerPopup",in:first,window:window)
        wait("window.open creates a tab using WebKit's supplied child configuration") {
            first.tabs.count == 3 && first.webView.title == "Fixture Message" && !first.webView.isLoading
        }
        let messageTab=first.selectedTabID
        expect(js("window.opener !== null",in:first) as? Bool == true,"popup child retains its actual window.opener")
        wait("popup postMessage reaches the original opener") {
            (js("window.popupMessages.includes('owned-popup-ready')",in:originalView) as? Bool) == true
        }
        first.selectTab(id:popupTab)
        let popupView=first.webView,popupToken=js("window.cardToken",in:first) as? String
        first.load(base.appendingPathComponent("two"))
        wait("tab navigation updates only that tab") { first.webView.title == "Fixture Two" && !first.webView.isLoading }
        first.selectTab(id:originalTab)
        expect(first.webView === originalView && first.webView.url?.path == "/one","another tab's navigation does not replace the selected page")
        first.selectTab(id:popupTab)
        click("browserBack",in:first)
        wait("each tab owns an independent back-forward history") { first.webView.title == "Fixture Popup" && !first.webView.isLoading }
        expect(first.webView === popupView,"back navigation keeps the same per-tab WebKit view")
        expect(popupToken != nil,"popup had a real independent page instance")
        first.selectTab(id:originalTab)
        expect(shortcut("}",code:30,flags:[.command,.shift],pane:first,window:window) && first.selectedTabID == popupTab,
               "real shifted-bracket key selects the next tab")
        expect(shortcut("{",code:33,flags:[.command,.shift],pane:first,window:window) && first.selectedTabID == originalTab,
               "real shifted-bracket key selects the previous tab")
        expect(shortcut("\t",code:48,flags:[.control],pane:first,window:window) && first.selectedTabID == popupTab,
               "Control-Tab selects the next tab")
        expect(shortcut("\u{19}",code:48,flags:[.control,.shift],pane:first,window:window) && first.selectedTabID == originalTab,
               "Control-Shift-Tab accepts the real back-tab character")
        first.closeTab(id:messageTab);first.closeTab(id:popupTab)
        expect(shortcut("t",code:17,pane:first,window:window) && first.tabs.count == 2 && first.currentURL == nil,
               "Command-T opens a blank tab without loading an external page")
        expect(first.tabs.last?.url == "" && first.lastPreviewSampleTime == nil,"blank tabs persist an empty URL and invalidate another tab's preview")
        let blankAddress:NSTextField=find("browserAddress",in:first,as:NSTextField.self)
        expect(blankAddress.currentEditor() != nil,"new blank tab focuses the address field")
        expect(shortcut("w",code:13,pane:first,window:window) && first.tabs.count == 1 && first.selectedTabID == originalTab,
               "Command-W closes only the selected tab and restores its neighbor")
        wait("complete tab state and selection reach the persistence callback") { savedTabs == first.tabs && savedSelection == first.selectedTabID }
        let firstToken=js("window.cardToken",in:first) as? String
        let viewport=first.webView.bounds
        guard let initial=preview(first) else { fatalError("Visible owned browser snapshot failed") }
        let initialColor=rgb(initial)
        let initialSample=first.lastPreviewSampleTime
        expect(initialSample != nil && initialSample! > 0 && initialSample! <= ProcessInfo.processInfo.systemUptime,
               "successful preview records monotonic capture time")
        let cachedRequests=first.testingSnapshotRequests
        _=preview(first)
        expect(first.lastPreviewSampleTime == initialSample && first.testingSnapshotRequests == cachedRequests,
               "cache hit neither captures again nor labels an old image fresh")
        first.setActive(false);first.isHidden=true;second.isHidden=false;second.setActive(true);second.focus()
        let responder=window.firstResponder
        first.focus()
        expect(window.firstResponder === responder && !first.isActive && second.isActive,"inactive pane never steals selected browser focus")
        expect(!first.performKeyEquivalent(with:cmdL),"inactive browser never consumes Command-L")
        let tick=(js("window.tick",in:first) as? NSNumber)?.intValue ?? 0
        _=js("document.body.style.backgroundColor='#ee3344';true",in:first)
        settle(1.2)
        expect(((js("window.tick",in:first) as? NSNumber)?.intValue ?? 0) > tick,"hidden attached page JavaScript continues while another card is active")
        expect(js("window.cardToken",in:first) as? String == firstToken && first.webView.bounds == viewport,"switching preserves page instance, history and viewport")
        guard let hidden=preview(first) else { fatalError("Hidden attached browser snapshot unavailable; coordinator needs a covered/offscreen host") }
        let hiddenColor=rgb(hidden)
        expect(hiddenColor.redComponent > 0.8 && hiddenColor.redComponent > initialColor.redComponent+0.3,"hidden preview reflects changed website pixels")
        expect(first.lastPreviewSampleTime! > initialSample!,"successful hidden capture advances actual sample time")
        expect(window.firstResponder === responder && first.isHidden,"hidden preview never reveals or focuses the background card")
        settle(0.9)
        let requests=first.testingSnapshotRequests
        var completions=0
        for _ in 0..<12 { first.takePreview { _ in expect(Thread.isMainThread,"batched completion stays on main");completions += 1 } }
        wait("all concurrent preview requests complete within a bounded interval",timeout:4) { completions == 12 }
        expect(first.testingSnapshotRequests-requests == 1,"concurrent callers share one underlying WebKit capture")
        // Deliver only owned events to an inactive source. Its content remains
        // covered by the selected sibling; no global input or app activation.
        first.isHidden=false;domClick("popup",in:first,window:window);first.isHidden=true;second.focus()
        let selectedResponder=window.firstResponder
        wait("a real popup from an inactive pane adds a background tab") { first.tabs.count == 2 }
        expect(first.selectedTabID == originalTab && !first.isActive && second.isActive,
               "inactive-source popup preserves that window's selected tab and active sibling")
        expect(window.firstResponder === selectedResponder,"background popup creation never steals selected sibling focus")
        let backgroundPopup=first.tabs.first { $0.id != originalTab }!.id
        first.selectTab(id:backgroundPopup)
        wait("background popup retains an independent loaded WebKit page") { first.webView.title == "Fixture Popup" && !first.webView.isLoading }
        first.closeTab(id:backgroundPopup)
        expect(first.webView === originalView && first.selectedTabID == originalTab && window.firstResponder === selectedResponder,
               "inspecting and closing inactive tabs never reloads the original or takes focus")
        let dialogs=js("[confirm('Synthetic confirmation'),prompt('Synthetic text','default'),(()=>{alert('Synthetic message');return true})()]",in:first) as? [Any]
        expect(dialogs?.count == 3 && dialogs?[0] as? Bool == false && dialogs?[1] is NSNull,"background website dialogs complete without stealing focus or requesting input")
        expect(window.attachedSheet == nil,"background website dialogs create no sheet")
        first.isHidden=false;second.isHidden=true;first.setActive(true);second.setActive(false)
        foregroundDialogs(in:first,window:window)
        expect(!window.isKeyWindow,"foreground policy simulation restores the real non-key state")
        first.load(base.appendingPathComponent("auth"))
        wait("HTTP authentication is canceled without a credential dialog") { first.hasError && !first.webView.isLoading }
        expect(window.attachedSheet == nil,"HTTP authentication never creates a native password sheet")
        first.load(base.appendingPathComponent("recover"))
        wait("network failure has an inline retry state") { first.hasError && !first.webView.isLoading }
        settle(0.15)
        expect(first.currentURL?.path == "/recover" && first.tabs.first(where:{$0.id == first.selectedTabID})?.url == base.appendingPathComponent("recover").absoluteString,
               "provisional failure preserves the requested destination despite previous-page WebKit callbacks")
        var armed=false
        URLSession.shared.dataTask(with:base.appendingPathComponent("arm")) { _,_,_ in DispatchQueue.main.async { armed=true } }.resume()
        wait("owned recovery fixture is ready") { armed }
        click("browserRetry",in:first)
        wait("Retry recovers the failed page") { first.webView.title == "Fixture Recovered" && !first.webView.isLoading && !first.hasError }
        let privateMarker="synthetic-private-token"
        for (code,category) in [(NSURLErrorCannotFindHost,"DNS"),(NSURLErrorDNSLookupFailed,"DNS"),
                               (NSURLErrorNotConnectedToInternet,"offline"),(NSURLErrorNetworkConnectionLost,"interrupted"),
                               (NSURLErrorTimedOut,"too long"),(NSURLErrorCannotConnectToHost,"server or network"),
                               (NSURLErrorSecureConnectionFailed,"HTTPS certificate"),(NSURLErrorServerCertificateUntrusted,"HTTPS certificate"),
                               (NSURLErrorAppTransportSecurityRequiresSecureConnection,"HTTPS address")] {
            let failure=NSError(domain:NSURLErrorDomain,code:code,userInfo:[
                NSLocalizedDescriptionKey:"Never echo "+privateMarker,
                NSURLErrorFailingURLStringErrorKey:"https://sensitive.invalid/private?token="+privateMarker])
            first.webView(first.webView,didFailProvisionalNavigation:nil,withError:failure)
            let message:NSTextField=find("browserError",in:first,as:NSTextField.self)
            expect(first.hasError && message.stringValue.contains(category),"native network failure presents its actionable category: \(category)")
            expect(!message.stringValue.contains(privateMarker) && !message.stringValue.contains("sensitive.invalid") && window.attachedSheet == nil,
                   "network failure never exposes private URL/description data or creates a sheet")
        }
        first.load(base.appendingPathComponent("recover"))
        wait("synthetic network error states recover through the same selected tab") { first.webView.title == "Fixture Recovered" && !first.webView.isLoading && !first.hasError }
        let retainedTab=first.selectedTabID,retainedView=first.webView
        guard let stalledA=first.addTab(url:base.appendingPathComponent("stall-a")) else { fatalError("Owned stalled tab A missing") }
        let stalledViewA=first.webView
        let reloadControl:NSButton=find("browserReload",in:first,as:NSButton.self)
        wait("server-confirmed stalled navigation A exposes Stop") { serverSaw("/stall-a",events:fixtureEvents) && stalledViewA.isLoading && reloadControl.toolTip == "Stop loading website" }
        guard let stalledB=first.addTab(url:base.appendingPathComponent("stall-b")) else { fatalError("Owned stalled tab B missing") }
        let stalledViewB=first.webView
        wait("server-confirmed stalled navigation B loads independently") { serverSaw("/stall-b",events:fixtureEvents) && stalledViewB.isLoading && reloadControl.toolTip == "Stop loading website" }
        first.selectTab(id:stalledA)
        expect(stalledViewB.isLoading && reloadControl.accessibilityLabel() == "Stop loading website","switching tabs points Stop at the selected loading page")
        click("browserReload",in:first)
        wait("Stop cancels the selected stalled navigation",diagnostics:{"A loading=\(stalledViewA.isLoading),B loading=\(stalledViewB.isLoading),control=\(reloadControl.toolTip ?? "nil")"}) { !stalledViewA.isLoading && reloadControl.toolTip == "Reload website" }
        expect(stalledViewB.isLoading && first.currentURL?.path == "/stall-a" && !first.hasError,
               "stopping A preserves its retry address and does not stop loading B or invent a network error")
        first.selectTab(id:stalledB)
        expect(reloadControl.toolTip == "Stop loading website","selecting still-loading B restores its own Stop state")
        click("browserReload",in:first)
        wait("Stop also cancels selected B without replacing either tab") { !stalledViewB.isLoading && reloadControl.toolTip == "Reload website" }
        expect(!stalledViewA.isLoading && first.currentURL?.path == "/stall-b","tab-specific Stop preserves both independent addresses")
        var released=false
        URLSession.shared.dataTask(with:base.appendingPathComponent("release-stalls")) { _,_,_ in DispatchQueue.main.async { released=true } }.resume()
        wait("owned stalled responses are released") { released }
        first.selectTab(id:stalledA);click("browserReload",in:first)
        wait("Reload retries A's canceled provisional destination") { first.webView.title == "Fixture Stall A" && !first.webView.isLoading && !first.hasError }
        first.selectTab(id:stalledB);click("browserReload",in:first)
        wait("Reload retries B's own canceled destination") { first.webView.title == "Fixture Stall B" && !first.webView.isLoading && !first.hasError }
        first.closeTab(id:stalledB);first.closeTab(id:stalledA);first.selectTab(id:retainedTab)
        expect(first.webView === retainedView && first.webView.title == "Fixture Recovered","stopping/retrying other tabs preserves the original live page")
        let restoreTabs=[BrowserTab(id:UUID().uuidString,title:"Unvisited",url:base.appendingPathComponent("one").absoluteString),
                         BrowserTab(id:UUID().uuidString,title:"Selected",url:base.appendingPathComponent("two").absoluteString)]
        let restored=BrowserScreenPane(screen:BrowserScreen(id:UUID().uuidString,title:"Restored window",tabs:restoreTabs,selectedTabID:restoreTabs[1].id),loadImmediately:false,dataStore:dataStore)
        restored.frame=host.bounds;host.addSubview(restored);restored.isHidden=true
        defer { restored.stop();restored.removeFromSuperview() }
        expect(restored.tabs == restoreTabs && restored.selectedTabID == restoreTabs[1].id && restored.testingLoadedTabCount == 1,
               "restoration keeps every tab and selection while creating only the selected WebKit view")
        restored.selectTab(id:restoreTabs[1].id)
        wait("restored selected tab loads independently") { restored.webView.title == "Fixture Two" && !restored.webView.isLoading }
        let restoredView=restored.webView
        restored.selectTab(id:restoreTabs[0].id)
        wait("first visit lazily loads the other restored tab") { restored.webView.title == "Fixture One" && !restored.webView.isLoading }
        expect(restored.testingLoadedTabCount == 2,"only visited restored tabs create live WebKit views")
        restored.selectTab(id:restoreTabs[1].id)
        expect(restored.webView === restoredView,"returning to a restored tab preserves its live instance")
        for _ in 0..<10 { expect(restored.addTab(select:false) != nil,"background blank tab fits within twelve-tab bound") }
        expect(restored.tabs.count == 12 && restored.testingLoadedTabCount == 2,"unvisited blank tabs are metadata-only")
        expect(restored.addTab() == nil && restored.tabs.count == 12,"thirteenth tab is rejected without replacing existing tabs")
        for tab in restored.tabs { restored.closeTab(id:tab.id) }
        expect(restored.tabs.count == 1 && restored.tabs[0].url.isEmpty && restored.currentURL == nil,
               "closing the last tab retains a usable blank window without persisting about:blank")
        expect(restored.testingLoadedTabCount == 1,"closed tabs release their native WebKit views")
        var blankPreviewFinished=false
        restored.takePreview { expect($0 == nil,"blank new-tab page does not capture another tab's preview");blankPreviewFinished=true }
        expect(blankPreviewFinished,"blank preview completes synchronously without WebKit work")
        let beforeStopSample=first.lastPreviewSampleTime
        first.stop();var stoppedCompletion=false
        first.takePreview { image in expect(image == nil,"stopped pane produces no preview");stoppedCompletion=true }
        expect(stoppedCompletion && !first.webView.isLoading,"eviction stop cancels loading and preview delivery without clearing cookies")
        expect(first.lastPreviewSampleTime == beforeStopSample,"stopped preview completion never invents a fresh capture timestamp")
        expect(!window.isKeyWindow,"all owned events remain offscreen and never activate the app")
        let report:[String:Any]=["checks":checks,"webKitFixtureScope":"owned127.0.0.1 HTTP pages; ephemeral shared cookies",
            "hiddenAttachedSnapshot":"updated pixels verified while another pane active","snapshotPixelBound":"256x160",
            "viewportPreserved":true,"HTTPAuthentication":"canceled without credential UI","globalInputEvents":0,
            "foregroundJavaScriptDialogs":"alert acknowledgement, confirm accept/cancel, prompt accept/cancel; owned invisible sheets and synthetic text",
            "foregroundPolicySimulation":"test-window isKeyWindow override only; no app activation or global input",
            "tabs":"independent WebKit/history, lazy restoration, selected persistence callback, keyboard/new/close,12-tab bound, last-tab blank",
            "navigationControl":"Reload/Stop selected-tab isolation; canceled provisional destination retry; sanitized DNS/offline/timeout/TLS/ATS messages",
            "popups":"target-blank and window.open stay in browser window; child opener/postMessage verified; inactive source preserves selection/focus",
            "macOS":ProcessInfo.processInfo.operatingSystemVersionString]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
        print("PASS: \(checks) owned native WebKit navigation, forms, preview, keyboard and lifecycle checks")
    }
}
