// SPDX-License-Identifier: GPL-2.0-or-later
// Actual ViewerController with only fake external launches and credentials.
import AppKit
import MetalKit
import WebKit
import Foundation

private final class FakeExternalWorkspaceLauncher: ExternalBrowserLaunching {
    struct Open { let url:URL;let applicationURL:URL;let completion:(Result<Void,Error>)->Void }
    var installed:[String:URL]=Dictionary(uniqueKeysWithValues:BrowserApplication.allCases.map { ($0.bundleIdentifier,URL(fileURLWithPath:"/OwnedFixture/"+$0.displayName+".app")) })
    var running=Set<String>(),opens:[Open]=[],activations:[String]=[]
    func applicationURL(bundleIdentifier:String)->URL? { installed[bundleIdentifier] }
    func isRunning(bundleIdentifier:String)->Bool { running.contains(bundleIdentifier) }
    func activate(bundleIdentifier:String)->Bool { activations.append(bundleIdentifier);return running.contains(bundleIdentifier) }
    func open(url:URL,applicationURL:URL,completion:@escaping(Result<Void,Error>)->Void) { opens.append(Open(url:url,applicationURL:applicationURL,completion:completion)) }
}
private final class EmptyExternalCredentials: PasswordStorage {
    var reads=0,saves=0,removals=0
    func read(host:String,port:UInt16)throws->String? { reads += 1;return nil }
    func save(host:String,port:UInt16,password:String)throws { saves += 1;fatalError("Unexpected credential save") }
    func remove(host:String,port:UInt16)throws { removals += 1 }
}

@main
struct ExternalWorkspaceHarness {
    private static var checks=0
    private static func expect(_ value:@autoclosure()->Bool,_ label:String) {
        checks += 1;guard value() else { fatalError("External workspace: "+label) }
    }
    private static func settle() { RunLoop.current.run(until:Date(timeIntervalSinceNow:0.03)) }
    private static func views(_ view:NSView)->[NSView] { [view]+view.subviews.flatMap(views) }
    private static func find<T:NSView>(_ id:String,in root:NSView,as type:T.Type)->T {
        guard let control=views(root).first(where:{$0.identifier?.rawValue == id && !$0.isHiddenOrHasHiddenAncestor}) as? T else { fatalError("Missing visible owned control: "+id) }
        return control
    }
    private static func close(_ controller:ViewerController) {
        controller.stop()
        if let window=controller.window { window.delegate=nil;window.orderOut(nil);window.close() }
    }
    private static func noWebKit(_ controller:ViewerController,_ message:String) {
        expect(controller.window?.contentView.map { !views($0).contains{$0 is WKWebView || $0 is BrowserScreenPane} } == true,message)
    }
    static func main() throws {
        guard MTLCreateSystemDefaultDevice() != nil,!NSScreen.screens.isEmpty else {
            fputs("UNAVAILABLE: owned external workspace checks require Metal/WindowServer (exit77).\n",stderr);exit(77)
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let suite="LanternVNC.ExternalWorkspace."+UUID().uuidString
        let preferences=UserDefaults(suiteName:suite)!
        preferences.removePersistentDomain(forName:suite)
        preferences.set(try JSONEncoder().encode([SavedDevice]()),forKey:"savedDevices.v1")
        preferences.set("127.0.0.1",forKey:"server");preferences.set("5900",forKey:"port");preferences.set(false,forKey:"clipboard")
        defer { preferences.removePersistentDomain(forName:suite) }
        let records=BrowserScreenStore(defaults:preferences)
        let safari=try records.add(title:"Owned Safari",url:"https://safari.fixture.example/start",browserBundleIdentifier:BrowserApplication.safari.bundleIdentifier)
        let chrome=try records.add(title:"Owned Chrome",url:"https://chrome.fixture.example/start",browserBundleIdentifier:BrowserApplication.chrome.bundleIdentifier)
        preferences.set(safari.id,forKey:"workspaceSelectedBrowser")
        let launcher=FakeExternalWorkspaceLauncher(),credentials=EmptyExternalCredentials()
        let productionBefore=UserDefaults.standard.persistentDomain(forName:"local.lantern.vnc")
        let controller=try ViewerController(showWindow:false,preferences:preferences,passwordStore:credentials,externalBrowserLauncher:launcher)
        defer { close(controller) }
        guard let window=controller.window,let root=window.contentView else { fatalError("Missing owned controller window") }
        window.ignoresMouseEvents=true;window.setFrameOrigin(NSPoint(x:-12000,y:-12000));root.layoutSubtreeIfNeeded()
        expect(launcher.opens.isEmpty && launcher.activations.isEmpty,"controller construction never starts or focuses an installed browser")
        noWebKit(controller,"external cards create no WKWebView or internal browser pane during construction")
        controller.testingStartSavedPreviews()
        expect(controller.testingSelectedBrowserID == safari.id && launcher.opens.isEmpty && launcher.activations.isEmpty,"saved selected external card restores without opening or activating its browser")
        noWebKit(controller,"startup preview restoration skips WebKit for every external card")
        expect(controller.testingBrowserPane(id:safari.id) == nil && controller.testingBrowserPane(id:chrome.id) == nil && controller.testingExternalPanelCount == 1,"restored Safari uses one typed external panel and neither external card uses WebKit")
        expect(controller.testingComputerCount == 0 && controller.testingCurrentSession == nil && controller.testingDesktop.framesReceived == 0,"external restoration starts no VNC connection or renderer updates")
        let originalOrder=controller.testingScreenOrder
        expect(originalOrder == ["browser:"+safari.id,"browser:"+chrome.id],"external cards begin in saved order")
        controller.testingSelectBrowser(id:safari.id)
        expect(launcher.opens.count == 1 && launcher.opens[0].url.absoluteString == safari.url && launcher.opens[0].applicationURL == launcher.installed[BrowserApplication.safari.bundleIdentifier],"first explicit Safari selection targets exactly its saved URL and app")
        controller.testingSelectBrowser(id:safari.id)
        expect(launcher.opens.count == 1 && launcher.activations.isEmpty,"pending repeated selection coalesces without another browser tab")
        launcher.running.insert(BrowserApplication.safari.bundleIdentifier);launcher.opens[0].completion(.success(()))
        controller.testingSelectBrowser(id:safari.id)
        expect(launcher.opens.count == 1 && launcher.activations == [BrowserApplication.safari.bundleIdentifier],"later Safari selection only activates the real browser")
        controller.testingSelectBrowser(id:chrome.id)
        expect(launcher.opens.count == 2 && launcher.opens[1].url.absoluteString == chrome.url,"first explicit Chrome selection uses the Chrome record rather than a WebKit substitute")
        launcher.running.insert(BrowserApplication.chrome.bundleIdentifier);launcher.opens[1].completion(.success(()))
        controller.testingSelectBrowser(id:safari.id);controller.testingSelectBrowser(id:chrome.id)
        expect(launcher.opens.count == 2 && controller.testingScreenOrder == originalOrder,"selecting either running browser does not add tabs or reorder online cards")
        noWebKit(controller,"all actual-browser selection/switch paths remain free of WKWebView")
        let openCount=launcher.opens.count
        let action:NSButton=find("externalBrowserOpenWebsite",in:root,as:NSButton.self)
        expect(action.sendAction(action.action,to:action.target),"typed external panel Open Website action is connected to the controller")
        expect(launcher.opens.count == openCount+1 && launcher.opens.last?.url.absoluteString == chrome.url,"explicit Open Website intentionally opens the saved URL again")
        launcher.opens.last!.completion(.success(()))
        try controller.testingEditBrowser(id:chrome.id,title:"Renamed external Chrome",url:"https://chrome.fixture.example/changed")
        controller.testingSelectBrowser(id:chrome.id)
        let address:NSTextField=find("externalBrowserURL",in:root,as:NSTextField.self)
        expect(address.stringValue == "https://chrome.fixture.example/changed" && launcher.opens.count == openCount+1,"editing URL updates panel state while normal selection still only activates")
        let stored=BrowserScreenStore(defaults:preferences).screens.first{$0.id == chrome.id}!
        expect(stored.title == "Renamed external Chrome" && stored.browserBundleIdentifier == BrowserApplication.chrome.bundleIdentifier,"renaming/navigation never silently converts actual Chrome into an in-app engine")

        let beforeRestart=launcher.opens.count,beforeActivation=launcher.activations.count
        let restarted=try ViewerController(showWindow:false,preferences:preferences,passwordStore:credentials,externalBrowserLauncher:launcher)
        restarted.testingStartSavedPreviews()
        expect(restarted.testingSelectedBrowserID == chrome.id && launcher.opens.count == beforeRestart && launcher.activations.count == beforeActivation,"application restart restores external kind/selection without launching or focusing any browser")
        noWebKit(restarted,"restart keeps external browser records out of WebKit")
        expect(BrowserScreenStore(defaults:preferences).screens.map(\.browserBundleIdentifier) == [BrowserApplication.safari.bundleIdentifier,BrowserApplication.chrome.bundleIdentifier],"both browser choices persist across controller reconstruction")
        close(restarted)
        expect(launcher.running == Set(BrowserApplication.allCases.map(\.bundleIdentifier)),"closing the owned Lantern controller does not close either actual browser")

        launcher.running.remove(BrowserApplication.safari.bundleIdentifier);controller.testingWorkspaceTick()
        expect(controller.testingScreenOrder == ["browser:"+chrome.id,"browser:"+safari.id],"closed external app moves its card below a running browser")
        controller.testingSelectBrowser(id:chrome.id)
        expect(controller.testingScreenOrder == ["browser:"+chrome.id,"browser:"+safari.id],"selecting the remaining online card does not reorder it")
        controller.testingSelectBrowser(id:safari.id)
        expect(launcher.opens.count == beforeRestart+1 && controller.testingScreenOrder == originalOrder,"explicitly reopening a closed browser restores its original online-card position")
        launcher.running.insert(BrowserApplication.safari.bundleIdentifier);launcher.opens.last!.completion(.success(()))
        controller.testingSelectBrowser(id:chrome.id);controller.testingSelectBrowser(id:safari.id)
        expect(controller.testingScreenOrder == originalOrder,"both reopened live cards remain in saved order through selection changes")

        let externalOpen:NSButton=find("externalBrowserOpenWebsite",in:root,as:NSButton.self)
        _=externalOpen.sendAction(externalOpen.action,to:externalOpen.target)
        let stale=launcher.opens.last!.completion,beforeRemoval=launcher.opens.count,beforeRemovalActivation=launcher.activations.count
        controller.testingRemoveBrowser(id:safari.id)
        expect(controller.testingSelectedBrowserID == chrome.id && launcher.opens.count == beforeRemoval && launcher.activations.count == beforeRemovalActivation,"removing selected external card selects fallback without opening or activating the other browser")
        expect(launcher.running.contains(BrowserApplication.safari.bundleIdentifier),"removing a card never terminates its external browser")
        let panelCount=controller.testingExternalPanelCount,managerCount=controller.testingExternalBrowserCount
        stale(.success(()));settle()
        expect(controller.testingExternalPanelCount == panelCount && controller.testingExternalBrowserCount == managerCount && !BrowserScreenStore(defaults:preferences).screens.contains{$0.id == safari.id},"stale removed-card completion cannot recreate manager, panel or persisted record")
        controller.testingRemoveBrowser(id:chrome.id)
        expect(controller.testingSelectedBrowserID == nil && controller.testingExternalPanelCount == 0 && controller.testingExternalBrowserCount == 0,"removing final external card safely restores the VNC view without a browser manager")
        expect(launcher.opens.count == beforeRemoval && launcher.activations.count == beforeRemovalActivation && launcher.running.contains(BrowserApplication.chrome.bundleIdentifier),"last-card fallback neither launches another browser nor closes the existing app")
        noWebKit(controller,"external removal and fallback never construct an internal WebKit browser")
        expect(controller.testingBrowserPreviewCount == 0 && controller.testingComputerCount == 0 && controller.testingCurrentSession == nil,"external cards never start screenshot sampling or VNC sessions")
        expect(credentials.saves == 0 && credentials.removals == 0,"external browser operations never save or remove any VNC credential")
        let damagedSuite=suite+".malformed",damaged=UserDefaults(suiteName:suite+".malformed")!
        defer { damaged.removePersistentDomain(forName:damagedSuite) }
        damaged.set(try JSONEncoder().encode([SavedDevice]()),forKey:"savedDevices.v1")
        damaged.set("127.0.0.1",forKey:"server");damaged.set("5900",forKey:"port")
        let blankTab=BrowserTab(id:UUID().uuidString,title:"New tab",url:"")
        let invalid=BrowserScreen(id:UUID().uuidString,title:"Malformed external blank",tabs:[blankTab],selectedTabID:blankTab.id,browserBundleIdentifier:BrowserApplication.chrome.bundleIdentifier)
        let valid=BrowserScreen(id:UUID().uuidString,title:"Valid external Safari",url:"https://safe.fixture.example",browserBundleIdentifier:BrowserApplication.safari.bundleIdentifier)
        damaged.set(try JSONEncoder().encode([invalid,valid]),forKey:"browserScreens.v1");damaged.set(invalid.id,forKey:"workspaceSelectedBrowser")
        expect(BrowserScreenStore(defaults:damaged).screens == [valid],"malformed external blank record is rejected while a neighboring valid record is preserved")
        let beforeDamaged=launcher.opens.count,beforeDamagedActivation=launcher.activations.count
        let recovered=try ViewerController(showWindow:false,preferences:damaged,passwordStore:credentials,externalBrowserLauncher:launcher)
        recovered.testingStartSavedPreviews()
        noWebKit(recovered,"restoring malformed external preferences never falls through to a WebKit pane or precondition")
        expect(launcher.opens.count == beforeDamaged && launcher.activations.count == beforeDamagedActivation,"malformed external restoration never launches or focuses an app")
        recovered.testingRestoreBrowser(id:valid.id)
        expect(recovered.testingSelectedBrowserID == valid.id && recovered.testingExternalPanelCount == 1,"valid external card remains usable after malformed neighbor recovery")
        close(recovered)
        expect(UserDefaults.standard.persistentDomain(forName:"local.lantern.vnc") as NSDictionary? == productionBefore as NSDictionary?,"actual Lantern preferences remain untouched")
        expect(!window.isVisible && !window.isKeyWindow && window.attachedSheet == nil,"owned integration window never becomes visible, captures focus or opens an authorization sheet")
        if CommandLine.arguments.count>1 {
            let receipt:[String:Any]=["checks":checks,"externalBrowserTypes":2,"realBrowserLaunches":0,"globalInputEvents":0,"webKitViewsForExternalCards":0,"profileAccess":"none","credentials":"injected empty fake","scope":"owned invisible controller and fake launcher; no external website requests or VNC sockets"]
            try JSONSerialization.data(withJSONObject:receipt,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
        }
        print("PASS: \(checks) external workspace/controller checks; fake launcher, no actual browser, profile, network or credentials")
    }
}
