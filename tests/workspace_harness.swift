// SPDX-License-Identifier: GPL-2.0-or-later
// Invisible owned controller, isolated defaults, fake credentials, loopback only.
import AppKit
import MetalKit
import WebKit
import Foundation

private final class WorkspaceCredentials: PasswordStorage {
    var values: [UInt16:String] = [:]
    var reads: [UInt16] = [], saves: [UInt16] = [], removals: [UInt16] = []
    func read(host: String, port: UInt16) throws -> String? {
        precondition(host == "127.0.0.1" || host == "unused.invalid")
        reads.append(port); return values[port]
    }
    func save(host: String, port: UInt16, password: String) throws {
        saves.append(port); values[port] = password
    }
    func remove(host: String, port: UInt16) throws { removals.append(port); values.removeValue(forKey:port) }
}

@main
struct WorkspaceHarness {
    private static var checks = 0
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else { fatalError("Workspace harness: " + message) }
    }
    private static func settle(_ duration: TimeInterval = 0.03) {
        RunLoop.current.run(until:Date(timeIntervalSinceNow:duration))
    }
    private static func wait(_ message: String, timeout: TimeInterval = 12, until ready: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow:timeout)
        while !ready() && Date() < deadline { settle() }
        expect(ready(),message)
    }
    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private static func find<T:NSView>(_ id: String, in root: NSView, as type: T.Type) -> T {
        guard let view = descendants(root).first(where:{$0.identifier?.rawValue == id}) as? T else {
            fatalError("Missing owned control: " + id)
        }
        return view
    }
    private static func image(_ id: String, kind: String, in root: NSView) -> NSImage? {
        let preview:NSImageView = find("screenCardPreview." + kind + ":" + id,in:root,as:NSImageView.self)
        return preview.image
    }
    private static func events(_ file: String) -> [[String:Any]] {
        guard let contents = try? String(contentsOfFile:file,encoding:.utf8) else { return [] }
        return contents.split(separator:"\n").compactMap { line in
            guard let data = String(line).data(using:.utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with:data)) as? [String:Any]
        }
    }
    private static func count(_ file: String, event: String, key: Int? = nil) -> Int {
        events(file).filter { $0["event"] as? String == event && (key == nil || $0["key"] as? Int == key) }.count
    }
    private static func key(_ character: String, code: UInt16, desktop: MetalDesktop, window: NSWindow) {
        for type in [NSEvent.EventType.keyDown,.keyUp] {
            let event = NSEvent.keyEvent(with:type,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,
                windowNumber:window.windowNumber,context:nil,characters:character,charactersIgnoringModifiers:character,
                isARepeat:false,keyCode:code)!
            if type == .keyDown { desktop.keyDown(with:event) } else { desktop.keyUp(with:event) }
        }
    }
    private static func js(_ source: String, pane: BrowserScreenPane) -> Any? {
        var done = false, result:Any?, failure:Error?
        pane.webView.evaluateJavaScript(source) { value,error in result=value;failure=error;done=true }
        wait("owned JavaScript completes") { done }
        expect(failure == nil,"owned JavaScript has no error")
        return result
    }
    private static func color(_ image: NSImage) -> NSColor {
        let cg = image.cgImage(forProposedRect:nil,context:nil,hints:nil)!
        return NSBitmapImageRep(cgImage:cg).colorAt(x:cg.width/2,y:cg.height/2)!.usingColorSpace(.deviceRGB)!
    }

    /// UUIDs are per connection, not endpoint names. Selection/reset and frame
    /// admission must be atomic even when old workers are still publishing.
    private static func routerChecks() {
        let tokenA=UUID(),tokenB=UUID(),oldGeneration=UUID()
        let journal=NSLock();var selected:UInt8=0,received=0,mismatches=0,resets=0
        let router=ScreenFrameRouter { bytes,width,height,stride,dirty in
            journal.lock();defer { journal.unlock() }
            received += 1
            if bytes[0] != selected || width != 1 || height != 1 || stride != 4 || dirty != FrameRegion(x:0,y:0,width:1,height:1) { mismatches += 1 }
        }
        let pixelA:[UInt8]=[1,0,0,0],pixelB:[UInt8]=[2,0,0,0]
        let rect=FrameRegion(x:0,y:0,width:1,height:1)
        func choose(_ token: UUID?, marker: UInt8) {
            router.select(token) { journal.lock();selected=marker;resets += 1;journal.unlock() }
        }
        pixelA.withUnsafeBufferPointer { a in pixelB.withUnsafeBufferPointer { b in
            choose(tokenA,marker:1)
            router.receive(token:oldGeneration,bytes:a.baseAddress!,width:1,height:1,stride:4,dirty:rect)
            expect(received == 0,"previous connection generation cannot paint the selected endpoint")
            router.receive(token:tokenA,bytes:a.baseAddress!,width:1,height:1,stride:4,dirty:rect)
            expect(received == 1,"exact selected token receives a frame")
            choose(tokenB,marker:2)
            router.receive(token:tokenA,bytes:a.baseAddress!,width:1,height:1,stride:4,dirty:rect)
            expect(received == 1,"previous target cannot paint after selection changes")
            let group=DispatchGroup(),queue=DispatchQueue(label:"owned.frame-router",attributes:.concurrent)
            for index in 0..<4000 {
                group.enter();queue.async {
                    let first=index % 2 == 0
                    choose(first ? tokenA : tokenB,marker:first ? 1 : 2)
                    router.receive(token:first ? tokenA : tokenB,bytes:first ? a.baseAddress! : b.baseAddress!,width:1,height:1,stride:4,dirty:rect)
                    group.leave()
                }
            }
            expect(group.wait(timeout:.now()+10) == .success,"4,000 concurrent selection/frame pairs complete")
            expect(mismatches == 0 && received > 1 && resets == 4002,"selection reset is atomic with frame admission")
            let before=received;choose(nil,marker:0)
            router.receive(token:tokenB,bytes:b.baseAddress!,width:1,height:1,stride:4,dirty:rect)
            expect(received == before,"browser/no-target selection blocks every VNC frame")
        } }
    }

    static func main() throws {
        guard CommandLine.arguments.count == 7,let portA=UInt16(CommandLine.arguments[1]),let portB=UInt16(CommandLine.arguments[2]),
              let base=URL(string:CommandLine.arguments[3]),base.host == "127.0.0.1" else { exit(2) }
        let logA=CommandLine.arguments[4],logB=CommandLine.arguments[5],report=CommandLine.arguments[6]
        routerChecks()
        guard MTLCreateSystemDefaultDevice() != nil,!NSScreen.screens.isEmpty else {
            fputs("UNAVAILABLE: workspace checks require Metal/WindowServer (exit 77).\n",stderr);exit(77)
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        let suite="LanternVNC.WorkspaceHarness."+UUID().uuidString
        let preferences=UserDefaults(suiteName:suite)!
        preferences.removePersistentDomain(forName:suite)
        preferences.set(try JSONEncoder().encode([SavedDevice]()),forKey:"savedDevices.v1")
        preferences.set("127.0.0.1",forKey:"server");preferences.set(String(portA),forKey:"port")
        preferences.set(false,forKey:"clipboard");preferences.set(true,forKey:"connectionPreferencesMigrated.v1")
        let profiles=DeviceStore(defaults:preferences)
        let first=profiles.save(name:"Owned computer A",host:"127.0.0.1",port:portA)!
        let second=profiles.save(name:"Owned computer B",host:"127.0.0.1",port:portB)!
        let third=profiles.save(name:"Unused owned profile",host:"unused.invalid",port:5999)!
        expect(profiles.save(name:"Fourth",host:"fourth.invalid",port:5998) == nil,"three-computer capacity rejects a fourth without opening any connection")
        let connectionPreferences=ConnectionPreferencesStore(defaults:preferences)
        expect(connectionPreferences.save(host:"127.0.0.1",port:portA,zoomMode:.fit,qualityIndex:1),"fixture A has lossless Fit settings")
        expect(connectionPreferences.save(host:"127.0.0.1",port:portB,zoomMode:.scale(1),qualityIndex:3),"fixture B has independent Wi-Fi/100-percent settings")
        let credentials=WorkspaceCredentials();credentials.values=[portA:"owned-fixture",portB:"owned-fixture"]
        let productionBefore=UserDefaults.standard.persistentDomain(forName:"local.lantern.vnc")
        let controller=try ViewerController(showWindow:false,preferences:preferences,passwordStore:credentials)
        let previousMenu=NSApp.mainMenu
        let menuOwner=AppDelegate();menuOwner.testingInstallMenu(controller:controller)
        controller.testingWorkspaceTick()
        let editMenu=NSApp.mainMenu!.items.first{$0.identifier?.rawValue == "workspaceEditMenu"}!
        expect(editMenu.isHidden && editMenu.submenu!.items.allSatisfy{$0.keyEquivalent.isEmpty},"VNC mode exposes no browser Edit shortcuts that could intercept remote Command keys")
        guard let window=controller.window,let root=window.contentView else { fatalError("Missing owned window") }
        defer {
            controller.stop();settle(0.15)
            NSApp.mainMenu=previousMenu
            window.delegate=nil;window.orderOut(nil);window.close()
            preferences.removePersistentDomain(forName:suite)
        }
        window.ignoresMouseEvents=true;window.setFrameOrigin(NSPoint(x:-12000,y:-12000));window.orderBack(nil)
        root.layoutSubtreeIfNeeded();settle()
        let desktop=controller.testingDesktop
        let zoom:NSPopUpButton=find("desktopZoom",in:root,as:NSPopUpButton.self)
        let quality:NSPopUpButton=find("pictureQuality",in:root,as:NSPopUpButton.self)
        let connect:NSButton=find("connectButton",in:root,as:NSButton.self)
        let viewOnly=descendants(root).compactMap{$0 as? NSButton}.first{$0.title == "View only"}!
        expect(!window.isKeyWindow,"owned controller never captures global keyboard focus")
        expect(controller.testingComputerCount == 0 && count(logA,event:"pixel-format") == 0 && count(logB,event:"pixel-format") == 0,"hidden controller never starts saved connections automatically")
        expect(descendants(root).compactMap{$0 as? ScreenCardView}.count == 3,"all three saved computer cards are represented")
        controller.testingStartSavedPreviews()
        wait("two owned VNC sessions connect and selected desktop receives frames") { controller.testingComputerCount == 2 && controller.testingComputerPreviewCount == 2 && connect.title == "Disconnect" && desktop.framesReceived > 0 }
        let sessionA=controller.testingComputerSession(id:first.id)!,sessionB=controller.testingComputerSession(id:second.id)!
        expect(controller.testingCurrentSession === sessionA,"current endpoint is selected without creating a separate foreground session")
        expect(quality.indexOfSelectedItem == 1 && zoom.indexOfSelectedItem == 1,"selected endpoint retains lossless quality and Fit")
        expect(!desktop.canPan && !controller.canMoveView,"small fixture fits without a misleading enabled pan control")
        key("a",code:0,desktop:desktop,window:window)
        wait("only selected server receives owned input") { count(logA,event:"key",key:97) == 2 }
        expect(count(logB,event:"key") == 0,"background VNC preview receives no selected-desktop input")
        desktop.onPointer?(1,1,1);desktop.onPointer?(1,1,0)
        wait("selected endpoint receives owned pointer callbacks") { count(logA,event:"pointer") == 2 }
        expect(count(logB,event:"pointer") == 0,"background preview receives no selected pointer events")
        viewOnly.state = .on;expect(viewOnly.sendAction(viewOnly.action,to:viewOnly.target),"view-only option is wired")
        key("v",code:9,desktop:desktop,window:window);settle(0.15)
        expect(count(logA,event:"key",key:118) == 0,"view-only blocks remote keyboard input")

        let browserA=try controller.testingAddBrowser(title:"Owned web A",url:base.appendingPathComponent("one").absoluteString)
        let paneA=controller.testingBrowserPane(id:browserA)!
        let browserB=try controller.testingAddBrowser(title:"Owned web B",url:base.appendingPathComponent("two").absoluteString)
        let paneB=controller.testingBrowserPane(id:browserB)!
        expect(!editMenu.isHidden && editMenu.submenu!.items.contains{$0.action == #selector(NSText.copy(_:)) && $0.keyEquivalent == "c"},"local browser mode restores standard Copy and other editing shortcuts")
        wait("both workspace browser pages load") { paneA.webView.title == "Fixture One" && paneB.webView.title == "Fixture Two" && !paneA.webView.isLoading && !paneB.webView.isLoading }
        expect(!paneA.webView.configuration.websiteDataStore.isPersistent,"hidden workspace uses an ephemeral browser store")
        let beforePopup=Set(BrowserScreenStore(defaults:preferences).screens.map{$0.id})
        paneA.onOpenURL?(base.appendingPathComponent("one"))
        let newPopup=BrowserScreenStore(defaults:preferences).screens.first{!beforePopup.contains($0.id)}!
        expect(controller.testingSelectedBrowserID == browserB && paneB.isActive,"a background-page popup cannot steal selected content or browser focus")
        expect(BrowserScreenStore(defaults:preferences).screens.count == 3,"background popup is saved as a separate browser card")
        controller.testingRemoveBrowser(id:newPopup.id)
        expect(controller.testingSelectedBrowserID == browserB,"closing the background popup preserves the selected browser")
        expect(controller.testingCurrentSession == nil && controller.testingComputerSession(id:first.id) === sessionA && controller.testingComputerSession(id:second.id) === sessionB,"browser changes selected routing while both original VNC sessions remain alive")
        expect(viewOnly.state == .on && quality.indexOfSelectedItem == 1,"browser selection leaves VNC view-only and quality choices intact")
        let frameCount=desktop.framesReceived
        key("x",code:7,desktop:desktop,window:window)
        // Exercise the controller gate independently of the renderer's
        // view-only guard: even an unexpected hidden callback cannot leak.
        desktop.onKey?(120,true);desktop.onKey?(120,false)
        desktop.onPointer?(2,2,1);desktop.onPointer?(2,2,0)
        let previewA=image(first.id,kind:"computer",in:root),previewB=image(second.id,kind:"computer",in:root)
        settle(2.25);controller.testingWorkspaceTick()
        wait("both background computer previews continue sampling") { image(first.id,kind:"computer",in:root) !== previewA && image(second.id,kind:"computer",in:root) !== previewB }
        expect(desktop.framesReceived == frameCount,"background VNC frames cannot paint the selected browser's hidden desktop")
        expect(count(logA,event:"key",key:120) == 0 && count(logB,event:"key",key:120) == 0,"owned key directed at hidden desktop is not routed to either VNC session")
        expect(count(logA,event:"pointer") == 2 && count(logB,event:"pointer") == 0,"browser routing gate also rejects unexpected hidden pointer callbacks")
        expect(count(logA,event:"pixel-format") == 1 && count(logB,event:"pixel-format") == 1,"browser selection opens no replacement VNC connection")
        let tokenA=js("window.cardToken",pane:paneA) as! String
        let tickA=(js("window.tick",pane:paneA) as! NSNumber).intValue
        _=js("document.body.style.backgroundColor='rgb(203,32,145)';true",pane:paneA)
        settle(2.1);controller.testingWorkspaceTick()
        wait("both visible and hidden browser cards acquire previews",timeout:8) { controller.testingBrowserPreviewCount == 2 }
        wait("hidden browser's newly sampled color reaches its card",timeout:8) {
            controller.testingWorkspaceTick()
            guard let thumbnail=image(browserA,kind:"browser",in:root) else { return false }
            let c=color(thumbnail);return abs(c.redComponent-203.0/255)<0.08 && abs(c.blueComponent-145.0/255)<0.08
        }
        expect((js("window.tick",pane:paneA) as! NSNumber).intValue > tickA,"hidden browser remains live rather than becoming a static screenshot")
        controller.testingSelectComputer(id:first.id)
        wait("returning to A resumes its retained session") { controller.testingCurrentSession === sessionA && desktop.framesReceived > 0 }
        expect(editMenu.isHidden && editMenu.submenu!.items.allSatisfy{$0.keyEquivalent.isEmpty},"returning to VNC removes local browser edit key equivalents")
        expect(viewOnly.state == .on && quality.indexOfSelectedItem == 1 && zoom.indexOfSelectedItem == 1,"returning to computer preserves view-only, lossless quality and Fit")
        viewOnly.state = .off;_=viewOnly.sendAction(viewOnly.action,to:viewOnly.target)
        controller.testingSelectComputer(id:second.id)
        wait("switching to B uses its retained connection") { controller.testingCurrentSession === sessionB && desktop.framesReceived > 0 }
        expect(quality.indexOfSelectedItem == 3 && zoom.indexOfSelectedItem == 4,"second computer restores its independent Wi-Fi quality and 100-percent zoom")
        key("b",code:11,desktop:desktop,window:window)
        wait("second selected computer receives its owned key") { count(logB,event:"key",key:98) == 2 }
        expect(count(logA,event:"key",key:98) == 0,"switching input target never leaks B's key to A")
        controller.testingSelectComputer(id:first.id)
        controller.testingSelectBrowser(id:browserA)
        expect(controller.testingBrowserPane(id:browserA) === paneA && (js("window.cardToken",pane:paneA) as? String) == tokenA,"browser switch returns to same live page without reloading")
        try controller.testingEditBrowser(id:browserA,title:"Edited owned web",url:base.appendingPathComponent("two").absoluteString)
        wait("editing URL navigates the same retained browser pane") { paneA.currentURL?.path == "/two" && paneA.webView.title == "Fixture Two" && !paneA.webView.isLoading }
        expect(controller.testingBrowserPane(id:browserA) === paneA && BrowserScreenStore(defaults:preferences).screens.first{$0.id == browserA}?.title == "Edited owned web","editing preserves browser identity and saves title in isolated preferences")
        do { try controller.testingEditBrowser(id:browserA,title:"Invalid",url:"javascript:alert(1)");expect(false,"unsupported browser edit must fail") }
        catch { expect(true,"unsupported browser edit is rejected without a sheet or external application") }
        expect(window.attachedSheet == nil && paneA.currentURL?.path == "/two","invalid edit leaves current page intact and opens no dialog")
        let back:NSButton=find("browserBack",in:paneA,as:NSButton.self)
        expect(back.isEnabled && back.sendAction(back.action,to:back.target),"workspace browser retains working local history")
        wait("Back returns to original owned page") { paneA.currentURL?.path == "/one" && !paneA.webView.isLoading }
        paneA.load(base.appendingPathComponent("recover"))
        wait("owned browser network failure stays inline") { paneA.hasError }
        expect(window.attachedSheet == nil,"browser network failure never opens a modal authentication dialog")
        var armed=false
        URLSession.shared.dataTask(with:base.appendingPathComponent("arm")) { _,_,_ in DispatchQueue.main.async { armed=true } }.resume()
        wait("owned recovery fixture is armed") { armed }
        let retry:NSButton=find("browserRetry",in:paneA,as:NSButton.self)
        expect(retry.sendAction(retry.action,to:retry.target),"inline browser retry is wired")
        wait("browser recovers without replacing VNC sessions") { !paneA.hasError && paneA.webView.title == "Fixture Recovered" && !paneA.webView.isLoading }
        controller.testingRemoveBrowser(id:browserA)
        expect(controller.testingSelectedBrowserID == browserB && controller.testingBrowserPane(id:browserA) == nil,"removing selected browser activates a surviving card safely")
        controller.testingRemoveBrowser(id:browserB)
        wait("removing final browser restores the retained VNC target") { controller.testingSelectedBrowserID == nil && controller.testingCurrentSession === sessionA && desktop.framesReceived > 0 }
        settle(0.2);controller.testingWorkspaceTick()
        expect(controller.testingBrowserPreviewCount == 0,"late removed-browser snapshot completions cannot recreate deleted previews")
        expect(count(logA,event:"pixel-format") == 1 && count(logB,event:"pixel-format") == 1,"all switching, navigation and removals preserve exactly one connection per VNC target")
        let encodingA=events(logA).first{$0["event"] as? String == "encodings"}?["values"] as? [Int] ?? []
        let encodingB=events(logB).first{$0["event"] as? String == "encodings"}?["values"] as? [Int] ?? []
        expect(encodingA.contains(-255) && !encodingA.contains(where:{(-32 ... -23).contains($0)}),"lossless computer retains compression1 and JPEG disabled")
        expect(encodingB.contains(-253) && encodingB.contains(-24),"Wi-Fi computer retains compression3 and coarse JPEG8")

        var resourceCards:[String]=[]
        var evictedPane:BrowserScreenPane?
        for index in 0..<7 {
            let id=try controller.testingAddBrowser(title:"Owned resource card \(index)",url:base.absoluteString+"/one?workspaceCard=\(index)")
            resourceCards.append(id)
            if index == 0 { evictedPane=controller.testingBrowserPane(id:id) }
            expect(resourceCards.filter { controller.testingBrowserPane(id:$0) != nil }.count <= 6,
                   "loaded browser count stays bounded while adding resource card \(index)")
        }
        let oldest=resourceCards[0],secondOldest=resourceCards[1]
        expect(controller.testingBrowserPane(id:oldest) == nil && resourceCards.filter { controller.testingBrowserPane(id:$0) != nil }.count == 6,
               "seventh browser evicts the least recently used inactive pane")
        expect(BrowserScreenStore(defaults:preferences).screens.count == 7 && DeviceStore(defaults:preferences).devices.count == 3,
               "sleeping browser records remain saved separately from the three-computer capacity")
        let stoppedRequests=evictedPane!.testingSnapshotRequests
        var stoppedPreviewDone=false,stoppedPreview:NSImage?
        evictedPane!.takePreview { stoppedPreview=$0;stoppedPreviewDone=true }
        wait("stopped evicted pane resolves preview request") { stoppedPreviewDone }
        expect(stoppedPreview == nil && evictedPane!.testingSnapshotRequests == stoppedRequests,
               "sleeping pane rejects new snapshots instead of restarting hidden work")
        controller.testingSelectBrowser(id:oldest)
        let resumed=controller.testingBrowserPane(id:oldest)!
        wait("selecting a sleeping card reloads its recorded URL") { resumed.webView.title == "Fixture One" && !resumed.webView.isLoading }
        expect(resumed !== evictedPane && resumed.currentURL?.query == "workspaceCard=0",
               "sleep resume creates a fresh pane while retaining the saved address")
        expect(controller.testingBrowserPane(id:secondOldest) == nil && resourceCards.filter { controller.testingBrowserPane(id:$0) != nil }.count == 6,
               "resuming an evicted page applies the same six-pane LRU bound")
        expect(controller.testingComputerSession(id:first.id) === sessionA && controller.testingComputerSession(id:second.id) === sessionB &&
               count(logA,event:"pixel-format") == 1 && count(logB,event:"pixel-format") == 1,
               "browser resource eviction never reconnects either VNC target")
        resourceCards.forEach { controller.testingRemoveBrowser(id:$0) }
        wait("removing resource-test pages restores VNC safely") { controller.testingSelectedBrowserID == nil && controller.testingCurrentSession === sessionA }
        settle(0.2);controller.testingWorkspaceTick()
        expect(controller.testingBrowserPreviewCount == 0 && resourceCards.allSatisfy { controller.testingBrowserPane(id:$0) == nil },
               "closed or evicted browser snapshots cannot recreate removed workspace previews")
        controller.testingRemoveComputer(id:first.id)
        wait("removing active computer closes only its owned session") { controller.testingComputerCount == 1 && controller.testingCurrentSession == nil && count(logA,event:"closed") == 1 }
        expect(controller.testingComputerPreviewCount == 1 && credentials.removals == [portA],"active removal clears its preview and calls only fake credential storage")
        controller.testingSelectComputer(id:second.id)
        wait("remaining computer still resumes its original session") { controller.testingCurrentSession === sessionB && desktop.framesReceived > 0 }
        controller.testingRemoveComputer(id:second.id)
        controller.testingRemoveComputer(id:third.id)
        wait("all owned computer sessions stop") { controller.testingComputerCount == 0 && count(logB,event:"closed") == 1 }
        settle(0.15)
        expect(controller.testingComputerPreviewCount == 0 && controller.testingCurrentSession == nil,"late removed-computer callbacks cannot repopulate thumbnails or selected session")
        expect(DeviceStore(defaults:preferences).devices.isEmpty && BrowserScreenStore(defaults:preferences).screens.isEmpty,"computer and browser removals persist independently in the isolated workspace")
        expect(credentials.saves.isEmpty,"automatic previews and switching never silently save entered or fixture credentials")
        expect(UserDefaults.standard.persistentDomain(forName:"local.lantern.vnc") as NSDictionary? == productionBefore as NSDictionary?,"production preferences remain untouched")
        expect(!window.isKeyWindow && window.attachedSheet == nil,"owned workspace finishes without user focus or an authorization sheet")
        let output:[String:Any] = ["checks":checks,"routerSelectionPairs":4000,"vncSessions":2,"vncReconnects":0,
            "browserPages":9,"maximumLoadedBrowserPanes":6,"scope":"owned offscreen controller; loopback fixtures; isolated preferences and fake passwords; no user app or global input"]
        try JSONSerialization.data(withJSONObject:output,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:report))
        print("PASS: \(checks) workspace integration checks, 4,000 concurrent router selection/frame pairs, two retained VNC sessions and six-pane browser LRU bounds")
    }
}
