// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Foundation

private final class FakeBrowserLauncher: ExternalBrowserLaunching {
    struct Open { let url:URL;let applicationURL:URL;let completion:(Result<Void,Error>)->Void }
    var installed:[String:URL]=[:],running=Set<String>(),activationSucceeds=true
    var opens:[Open]=[],activations:[String]=[]
    func applicationURL(bundleIdentifier:String)->URL? { installed[bundleIdentifier] }
    func isRunning(bundleIdentifier:String)->Bool { running.contains(bundleIdentifier) }
    func activate(bundleIdentifier:String)->Bool { activations.append(bundleIdentifier);return activationSucceeds }
    func open(url:URL,applicationURL:URL,completion:@escaping(Result<Void,Error>)->Void) { opens.append(Open(url:url,applicationURL:applicationURL,completion:completion)) }
}

private final class WeakBrowserManager {
    weak var value:ExternalBrowserManager?
    init(_ manager:ExternalBrowserManager?) { value=manager }
}

@main
struct ExternalBrowserTests {
    private static var checks=0
    private static func expect(_ value:@autoclosure()->Bool,_ label:String) {
        checks += 1;guard value() else { fatalError("External browser test: "+label) }
    }
    private static func wait(_ label:String,until ready:()->Bool) {
        let deadline=Date(timeIntervalSinceNow:3)
        while !ready() && Date()<deadline { RunLoop.current.run(until:Date(timeIntervalSinceNow:0.01)) }
        expect(ready(),label)
    }
    static func main() {
        let first=URL(string:"https://fixture.example/first?q=synthetic#section")!,second=URL(string:"http://127.0.0.1:8080/second")!
        let failure=NSError(domain:"OwnedFixture",code:7,userInfo:[NSLocalizedDescriptionKey:"Synthetic opening failure."])
        expect(BrowserApplication.safari.bundleIdentifier == "com.apple.Safari" && BrowserApplication.chrome.bundleIdentifier == "com.google.Chrome","installed browser identities are exact")
        expect(BrowserApplication.allCases.map(\.displayName) == ["Safari","Google Chrome"],"engine labels identify actual browsers")
        for browser in BrowserApplication.allCases {
            let fake=FakeBrowserLauncher(),app=URL(fileURLWithPath:"/OwnedFixture/"+browser.displayName+".app")
            fake.installed[browser.bundleIdentifier]=app
            let manager=ExternalBrowserManager(application:browser,launcher:fake)
            var statuses:[ExternalBrowserStatus]=[]
            manager.onStatusChanged={ expect(Thread.isMainThread,"status callbacks run on main");statuses.append($0) }
            expect(manager.status == .ready && fake.opens.isEmpty && fake.activations.isEmpty,"construction never launches or activates a browser")
            manager.select(website:first)
            expect(manager.status == .opening && fake.opens.count == 1 && fake.opens[0].url == first && fake.opens[0].applicationURL == app,"first selected card opens its URL in the chosen actual app")
            manager.select(website:first);manager.select(website:second);manager.refreshStatus()
            expect(fake.opens.count == 1 && fake.activations.isEmpty && manager.status == .opening,"repeated selection coalesces while the first open is pending")
            fake.running.insert(browser.bundleIdentifier);fake.opens[0].completion(.success(()))
            expect(manager.hasOpenedWebsite && manager.status == .running,"successful first open establishes reusable app selection")
            manager.select(website:first);manager.select(website:second)
            expect(fake.opens.count == 1 && fake.activations == [browser.bundleIdentifier,browser.bundleIdentifier],"later card selections only activate the app even if saved URL has changed")
            let before=statuses.count;manager.refreshStatus();manager.refreshStatus()
            expect(statuses.count == before,"unchanged status polling produces no redundant callbacks")
            manager.openWebsite(second)
            expect(fake.opens.count == 2 && fake.opens[1].url == second && manager.status == .opening,"explicit Open Website intentionally opens its supplied URL again")
            fake.opens[1].completion(.success(()))
            expect(manager.status == .running && fake.activations.count == 2,"explicit open completion does not perform a second activation")
            fake.running.remove(browser.bundleIdentifier);manager.refreshStatus()
            expect(manager.status == .closed,"closing the external browser is reflected without opening anything")
            manager.select(website:first)
            expect(fake.opens.count == 3 && manager.status == .opening,"selection after browser exit reopens the saved website")
            fake.running.insert(browser.bundleIdentifier);fake.opens[2].completion(.success(()))
            expect(manager.status == .running && manager.hasOpenedWebsite,"browser restart returns to the reusable-running state")
            fake.activationSucceeds=false;manager.select(website:first)
            if case .failed(let message)=manager.status { expect(message.contains(browser.displayName),"activation error identifies the actual browser") }
            else { fatalError("Activation failure was hidden") }
            expect(fake.opens.count == 3,"activation failure never silently opens duplicate website tabs")
            manager.refreshStatus()
            if case .failed = manager.status { checks += 1 } else { fatalError("Polling erased activation error") }
            fake.activationSucceeds=true;manager.select(website:first)
            expect(manager.status == .running && fake.opens.count == 3,"explicit selection retries activation without opening a URL")
            fake.running.remove(browser.bundleIdentifier);fake.installed.removeValue(forKey:browser.bundleIdentifier);manager.refreshStatus()
            expect(manager.status == .missing,"removed app is distinguished from a closed installed app")
            manager.select(website:first)
            expect(fake.opens.count == 3 && manager.status == .missing,"missing browser never falls back to a different browser or web engine")
            fake.installed[browser.bundleIdentifier]=app;manager.refreshStatus()
            expect(manager.status == .closed,"rediscovery of an installed browser preserves prior card history")
        }
        let fake=FakeBrowserLauncher();fake.installed[BrowserApplication.chrome.bundleIdentifier]=URL(fileURLWithPath:"/OwnedFixture/Chrome.app")
        let manager=ExternalBrowserManager(application:.chrome,launcher:fake)
        manager.openWebsite(first);manager.openWebsite(second)
        expect(fake.opens.count == 2,"separate explicit website actions retain their own requests")
        fake.opens[0].completion(.failure(failure))
        expect(manager.status == .opening && !manager.hasOpenedWebsite,"old request failure cannot overwrite a newer pending action")
        fake.running.insert(BrowserApplication.chrome.bundleIdentifier);fake.opens[1].completion(.success(()))
        expect(manager.status == .running && manager.hasOpenedWebsite,"newest successful completion wins")
        fake.opens[0].completion(.success(()))
        expect(manager.status == .running,"duplicate stale completion has no effect")
        let canceled=ExternalBrowserManager(application:.chrome,launcher:fake)
        canceled.select(website:first);let pending=fake.opens.last!
        canceled.cancelPending();expect(canceled.status == .ready && !canceled.hasOpenedWebsite,"cancel clears pending local state without inventing an opened website")
        pending.completion(.success(()));expect(canceled.status == .ready && !canceled.hasOpenedWebsite,"canceled launch completion cannot resurrect removed-card state")
        canceled.select(website:second);let current=fake.opens.last!
        pending.completion(.failure(failure));expect(canceled.status == .opening,"old canceled failure cannot overwrite a new attempt")
        current.completion(.failure(failure))
        if case .failed(let message)=canceled.status { expect(message.contains("Synthetic opening failure"),"current open error remains actionable") } else { fatalError("Open failure was hidden") }
        canceled.refreshStatus();if case .failed = canceled.status { checks += 1 } else { fatalError("Polling erased open error") }
        let before=fake.opens.count;canceled.select(website:first)
        expect(fake.opens.count == before+1,"failed first open can be explicitly retried")
        var mainCallback=false;canceled.onStatusChanged={ _ in mainCallback=Thread.isMainThread }
        let background=fake.opens.last!.completion
        DispatchQueue.global().async { background(.success(())) }
        wait("background completion is safely normalized to main") { canceled.status == .running && mainCallback }
        for raw in ["file:///tmp/owned","javascript:alert(1)","https://name:synthetic@fixture.example","http://fixture.example:0","http://fixture.example:65536","about:blank"] {
            let count=fake.opens.count
            canceled.openWebsite(URL(string:raw)!)
            if case .failed = canceled.status { checks += 1 } else { fatalError("Unsafe external URL was accepted") }
            expect(fake.opens.count == count,"invalid website never reaches system launcher")
        }
        var released:ExternalBrowserManager?=ExternalBrowserManager(application:.chrome,launcher:fake)
        let weakManager=WeakBrowserManager(released)
        released!.select(website:first);let afterRemoval=fake.opens.last!.completion
        released=nil;expect(weakManager.value == nil,"pending launcher callback does not retain a removed card manager")
        afterRemoval(.success(()));expect(weakManager.value == nil,"late completion after removal remains harmless")
        let reentrant=ExternalBrowserManager(application:.chrome,launcher:fake)
        reentrant.onStatusChanged={ [weak reentrant] status in if status == .opening { reentrant?.cancelPending() } }
        let beforeCancel=fake.opens.count;reentrant.select(website:first)
        expect(fake.opens.count == beforeCancel && reentrant.status == .ready,"cancellation during status callback prevents an unsubmitted OS open")
        if CommandLine.arguments.contains("--panel") { panelChecks(first) }
        print("PASS: \(checks) external-browser lifecycle, app selection, no-duplicate-tab, cancellation and URL checks; fake launcher only, no apps or profiles opened")
    }

    private static func panelChecks(_ website:URL) {
        guard !NSScreen.screens.isEmpty else { fputs("UNAVAILABLE: owned panel checks require WindowServer (exit77).\n",stderr);exit(77) }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let window=NSWindow(contentRect:NSRect(x:-12000,y:-12000,width:572,height:480),styleMask:[.borderless],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.ignoresMouseEvents=true
        defer { window.orderOut(nil);window.close() }
        func all(_ view:NSView)->[NSView] { [view]+view.subviews.flatMap(all) }
        for browser in BrowserApplication.allCases {
            let panel=ExternalBrowserPanel(application:browser);window.contentView=panel
            var selected=0,opened=0,edited=0,toggled=0
            panel.onOpenOrSwitch={selected += 1};panel.onOpenWebsite={opened += 1};panel.onChangeURL={edited += 1};panel.onToggleSidebar={toggled += 1}
            let ids=["externalBrowserOpenOrSwitch","externalBrowserOpenWebsite","externalBrowserChangeURL","externalBrowserSidebarToggle"]
            func button(_ id:String)->NSButton { all(panel).first{$0.identifier?.rawValue == id} as! NSButton }
            let statuses:[ExternalBrowserStatus]=[.ready,.opening,.running,.closed,.missing,.failed(String(repeating:"Owned synthetic error. ",count:35))]
            for size in [NSSize(width:572,height:480),NSSize(width:892,height:700),NSSize(width:1180,height:700)] {
                window.setContentSize(size)
                for status in statuses {
                    panel.update(url:website,status:status);panel.layoutSubtreeIfNeeded()
                    for id in ids {
                        let control=button(id),bounds=control.convert(control.bounds,to:panel)
                        expect(bounds.width>20 && bounds.height>10 && panel.bounds.insetBy(dx:-1,dy:-1).contains(bounds),"external panel control remains reachable at \(size): \(id)")
                    }
                    let enabled=status != .opening && status != .missing
                    expect(button(ids[0]).isEnabled == enabled && button(ids[1]).isEnabled == enabled,"open controls reflect unavailable/pending status")
                    expect(button(ids[2]).isEnabled == (status != .opening),"URL edit remains available when browser is missing")
                }
            }
            panel.update(url:website,status:.running)
            expect(button(ids[0]).title == "Switch to \(browser.displayName)","running browser button describes app switching")
            for id in ids { let control=button(id);expect(control.sendAction(control.action,to:control.target),"owned external-panel action is wired") }
            expect(selected == 1 && opened == 1 && edited == 1 && toggled == 1,"panel dispatches only the explicitly selected local callback")
            panel.setSidebarVisible(false);expect(button(ids[3]).toolTip == "Show connection sidebar","panel can restore a hidden sidebar")
            panel.update(url:nil,status:.failed("Set a valid website address."))
            expect(!button(ids[0]).isEnabled && !button(ids[1]).isEnabled && button(ids[2]).isEnabled,"invalid or missing URL offers correction without launching or falling back to WebKit")
            expect(all(panel).compactMap{$0 as? NSTextField}.contains{$0.stringValue.contains("outside Lantern")},"panel truthfully identifies an external browser window")
            expect(!window.isVisible && !window.isKeyWindow,"owned panel test never displays a window or captures focus")
        }
    }
}
