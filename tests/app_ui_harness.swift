// SPDX-License-Identifier: GPL-2.0-or-later
// Exercises the real controller in a test-owned offscreen window. It never
// connects to a server, activates the app, records a screen, or sends global input.
import AppKit
import MetalKit
import Foundation

private final class TestPasswordStore: PasswordStorage {
    var values: [String:String] = [:]
    private func key(_ host:String,_ port:UInt16)->String { "\(host.lowercased()):\(port)" }
    func read(host:String,port:UInt16)throws->String? { values[key(host,port)] }
    func save(host:String,port:UInt16,password:String)throws { values[key(host,port)]=password }
    func remove(host:String,port:UInt16)throws { values.removeValue(forKey:key(host,port)) }
}

@main
struct AppUIHarness {
    private static var checks=0
    private static func expect(_ condition: @autoclosure () -> Bool,_ message: String) {
        checks += 1
        guard condition() else { fatalError("App UI harness: \(message)") }
    }
    private static func settle(_ seconds: TimeInterval=0.04) {
        RunLoop.current.run(until:Date(timeIntervalSinceNow:seconds))
    }
    private static func allViews(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(allViews)
    }
    private static func find<T: NSView>(_ identifier: String,in root: NSView,as type: T.Type) -> T {
        guard let view=allViews(root).first(where:{$0.identifier?.rawValue == identifier}) as? T else {
            fatalError("Missing owned control: \(identifier)")
        }
        return view
    }
    private static func geometry(_ content: NSView) {
        for view in allViews(content) {
            let frame=view.frame
            expect(frame.origin.x.isFinite && frame.origin.y.isFinite && frame.width.isFinite && frame.height.isFinite,
                   "all owned view frames are finite")
            expect(frame.width >= 0 && frame.height >= 0,"all owned view sizes are nonnegative")
        }
        for identifier in ["desktopZoom","panViewButton","sidebarToggleButton"] {
            let control: NSView=find(identifier,in:content,as:NSView.self)
            let rectangle=control.convert(control.bounds,to:content)
            expect(rectangle.width > 8 && rectangle.height > 8,"toolbar control has a usable size: \(identifier)")
            expect(content.bounds.insetBy(dx:-1,dy:-1).contains(rectangle),"toolbar control is not clipped: \(identifier)")
        }
    }
    private static func choose(_ index: Int,in popup: NSPopUpButton) {
        popup.selectItem(at:index)
        expect(popup.sendAction(popup.action,to:popup.target),"zoom popup action is connected")
    }
    private static func action(_ selector: Selector,on controller: ViewerController) {
        expect(NSApp.sendAction(selector,to:controller,from:nil),"controller menu action is connected: \(selector)")
    }

    static func main() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            fputs("UNAVAILABLE: Metal access is required for the owned app UI harness (exit 77).\n",stderr)
            exit(77)
        }
        let application=NSApplication.shared
        application.setActivationPolicy(.accessory)
        let suiteName="LanternVNC.UIHarness.\(UUID().uuidString)"
        let preferences=UserDefaults(suiteName:suiteName)!
        preferences.removePersistentDomain(forName:suiteName)
        preferences.set("test-one.local",forKey:"server")
        preferences.set("5900",forKey:"port")
        let store=DeviceStore(defaults:preferences)
        _ = store.save(name:"Test two",host:"test-two.local",port:5901)
        _ = store.save(name:"Test three",host:"test-three.local",port:5902)
        let actualPreferencesBefore=UserDefaults.standard.persistentDomain(forName:"local.lantern.vnc")
        let passwordStore=TestPasswordStore()
        let controller=try ViewerController(showWindow:false,preferences:preferences,passwordStore:passwordStore)
        guard let window=controller.window,let content=window.contentView else { fatalError("Missing owned viewer window") }
        defer {
            controller.stop()
            window.delegate=nil
            window.orderOut(nil)
            window.close()
            preferences.removePersistentDomain(forName:suiteName)
        }
        expect(!window.isVisible && !window.isKeyWindow,"showWindow false does not show or focus a window")
        expect(window.frameAutosaveName.isEmpty,"headless controller does not read or write saved window geometry")
        window.ignoresMouseEvents=true
        window.setFrameOrigin(NSPoint(x:-10000,y:-10000))
        // AppKit/Metal needs a drawable-bearing window. This owned window stays
        // wholly outside every screen and is ordered behind other windows.
        window.orderBack(nil)
        window.setFrameOrigin(NSPoint(x:-10000,y:-10000))
        content.layoutSubtreeIfNeeded(); settle()
        expect(!window.isKeyWindow,"offscreen test never takes keyboard focus")
        let desktop=allViews(content).compactMap{$0 as? MetalDesktop}.first!
        let zoom: NSPopUpButton=find("desktopZoom",in:content,as:NSPopUpButton.self)
        let hand: NSButton=find("panViewButton",in:content,as:NSButton.self)
        let sidebar: NSButton=find("sidebarToggleButton",in:content,as:NSButton.self)
        let picker: NSPopUpButton=find("savedDevicePicker",in:content,as:NSPopUpButton.self)
        let password: NSSecureTextField=find("serverPassword",in:content,as:NSSecureTextField.self)
        expect(zoom.itemTitles == ["Auto (Readable)","Fit to Window","50%","75%","100%","125%","150%","200%"],"all supported zoom choices are present")
        expect(zoom.indexOfSelectedItem == 0 && desktop.zoomMode == .automatic,"new controller defaults to Auto Readable")
        expect(picker.numberOfItems == 3 && !picker.itemTitles.contains("Add device…"),"three saved devices fit in one picker without a fourth add action")
        expect(password.stringValue.isEmpty,"no password is loaded from preferences")
        expect(!hand.isEnabled,"Hand is disabled without an active session")

        let width=5120,height=2880
        let frame=Data(repeating:0,count:width*height*4)
        frame.withUnsafeBytes { source in
            desktop.receive(source.baseAddress!.assumingMemoryBound(to:UInt8.self),width:width,height:height,stride:width*4)
        }
        for _ in 0..<30 {
            settle(); desktop.draw()
            if desktop.remoteSize == CGSize(width:width,height:height) { break }
        }
        expect(desktop.remoteSize == CGSize(width:width,height:height),"synthetic 5K frame is received without a network connection")
        let horizontal: NSScroller=find("desktopHorizontalScroll",in:content,as:NSScroller.self)
        let vertical: NSScroller=find("desktopVerticalScroll",in:content,as:NSScroller.self)
        let sizes=[CGSize(width:860,height:540),CGSize(width:1180,height:760),CGSize(width:860,height:950),CGSize(width:1600,height:560)]
        for size in sizes {
            window.setContentSize(size)
            content.layoutSubtreeIfNeeded(); desktop.updateCanvas(); settle()
            geometry(content)
            expect(desktop.bounds.width > 100 && desktop.bounds.height > 100,"desktop viewport remains usable at \(size)")
            expect(desktop.frame.width < CGFloat(width) && desktop.frame.height < CGFloat(height),"Metal view stays viewport-sized at \(size)")
            expect(desktop.remoteSize == CGSize(width:width,height:height),"local window resize leaves remote resolution unchanged")
            choose(4,in:zoom)
            expect(desktop.zoomMode == .scale(1) && abs(desktop.displayScale-1) < 0.00001,"100% uses physical pixel scale")
            expect(!horizontal.isHidden && !vertical.isHidden,"both scrollbars remain visible for an oversized 5K desktop")
            for scroller in [horizontal,vertical] {
                let rectangle=scroller.convert(scroller.bounds,to:content)
                expect(content.bounds.insetBy(dx:-1,dy:-1).contains(rectangle),"native scrollbar remains inside the owned window")
                expect(scroller.knobProportion > 0 && scroller.knobProportion < 1,"scrollbar indicates navigable overflow")
            }
            choose(1,in:zoom)
            expect(desktop.zoomMode == .fit && !desktop.canPan,"Fit mode shows the entire remote desktop")
            expect(horizontal.isHidden && vertical.isHidden,"Fit mode hides unnecessary scrollbars")
            choose(0,in:zoom)
            expect(desktop.zoomMode == .automatic && desktop.displayScale >= 1,"Auto mode preserves readable physical scale")
            expect(zoom.indexOfSelectedItem == 0,"viewport callback preserves Auto popup selection")

            let priorWidth=desktop.bounds.width
            expect(sidebar.sendAction(sidebar.action,to:sidebar.target),"sidebar toolbar action is connected")
            content.layoutSubtreeIfNeeded(); desktop.updateCanvas(); settle()
            expect(!controller.isSidebarVisible && sidebar.state == .off,"toolbar hides the connection sidebar")
            expect(desktop.bounds.width > priorWidth+270,"hiding sidebar expands the desktop viewport")
            geometry(content)
            action(#selector(ViewerController.toggleSidebar),on:controller)
            content.layoutSubtreeIfNeeded(); desktop.updateCanvas(); settle()
            expect(controller.isSidebarVisible && sidebar.state == .on,"menu action restores the sidebar")
            expect(abs(desktop.bounds.width-priorWidth) < 1,"restoring sidebar restores the original viewport width")
            geometry(content)
        }

        desktop.zoomMode = .scale(1.17)
        expect(zoom.selectedItem?.title == "117% (Custom)","arbitrary pinch zoom is reflected in the popup")
        action(#selector(ViewerController.zoomIn),on:controller)
        expect(desktop.zoomMode == .scale(1.25) && zoom.indexOfSelectedItem == 5,"Zoom In action selects the next larger scale")
        action(#selector(ViewerController.zoomOut),on:controller)
        expect(desktop.zoomMode == .scale(1) && zoom.indexOfSelectedItem == 4,"Zoom Out action selects the next smaller scale")
        action(#selector(ViewerController.fitZoom),on:controller)
        expect(desktop.zoomMode == .fit && zoom.indexOfSelectedItem == 1,"Fit menu action updates both model and popup")
        action(#selector(ViewerController.automaticZoom),on:controller)
        expect(desktop.zoomMode == .automatic && zoom.indexOfSelectedItem == 0,"Auto menu action updates both model and popup")
        action(#selector(ViewerController.actualSize),on:controller)
        expect(desktop.zoomMode == .scale(1) && zoom.indexOfSelectedItem == 4,"Actual Size action resets to 100%")
        desktop.panMode=true
        expect(hand.state == .on,"viewport callback reflects Hand mode changes")
        let escape=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,
            windowNumber:window.windowNumber,context:nil,characters:"\u{1b}",charactersIgnoringModifiers:"\u{1b}",isARepeat:false,keyCode:53)!
        desktop.keyDown(with:escape)
        expect(!desktop.panMode && hand.state == .off,"Esc in Hand mode immediately updates the toolbar")
        desktop.panMode=true
        choose(1,in:zoom)
        expect(!desktop.panMode && !hand.isEnabled && hand.state == .off,"Fit clears unusable Hand mode without callback recursion")
        expect(password.stringValue.isEmpty,"all local display interactions leave password empty")
        expect(!window.isKeyWindow,"all local actions remain in a non-key offscreen window")
        let actualPreferencesAfter=UserDefaults.standard.persistentDomain(forName:"local.lantern.vnc")
        expect(NSDictionary(dictionary:actualPreferencesBefore ?? [:]).isEqual(to:actualPreferencesAfter ?? [:]),"production Lantern preferences remain unchanged")
        let saved=preferences.persistentDomain(forName:suiteName) ?? [:]
        expect(!saved.keys.contains(where:{$0.lowercased().contains("password")}),"UI interactions never persist a password")

        if let path=CommandLine.arguments.dropFirst().first {
            let report: [String:Any]=["uiChecks":checks,"windowSizes":sizes.map{"\(Int($0.width))x\(Int($0.height))"},
                "syntheticRemoteSize":"5120x2880","networkConnections":0,"globalInputEvents":0,
                "preferenceIsolation":"temporary UserDefaults suite","windowPresentation":"owned, offscreen, non-key",
                "macOS":ProcessInfo.processInfo.operatingSystemVersionString,"gpu":desktop.device?.name ?? "Unknown"]
            try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
                .write(to:URL(fileURLWithPath:path))
        }
        print("PASS: \(checks) owned offscreen controller layout, zoom, sidebar, and preference-isolation checks")
    }
}
