// SPDX-License-Identifier: GPL-2.0-or-later
// Geometry tests need no WindowServer. Native tests use invisible owned windows
// and one UUID autosave key, removed on exit; never the production frame name.
import AppKit
import Foundation

private final class PlacementProbeWindow: NSWindow {
    var centerCalls = 0
    var saveCalls = 0
    var pretendFullScreen = false
    override func center() { centerCalls += 1; super.center() }
    override func saveFrame(usingName name: NSWindow.FrameAutosaveName) {
        saveCalls += 1; super.saveFrame(usingName: name)
    }
    override var styleMask: NSWindow.StyleMask {
        get { pretendFullScreen ? super.styleMask.union(.fullScreen) : super.styleMask }
        set { super.styleMask = newValue }
    }
}

@main
struct WindowPlacementTests {
    private static var checks = 0
    private static func expect(_ value: @autoclosure () -> Bool, _ label: String) {
        checks += 1
        guard value() else { fatalError("Window placement test: \(label)") }
    }
    private static func close(_ window: PlacementProbeWindow) {
        window.setFrameAutosaveName("")
        window.delegate = nil; window.orderOut(nil); window.close()
    }

    static func main() {
        geometryTests()
        print("PASS: \(checks) pure window-placement geometry checks")
        if CommandLine.arguments.contains("--geometry-only") { return }
        guard !NSScreen.screens.isEmpty else {
            fputs("NOT RUN: native window autosave checks need WindowServer access (exit 77); geometry alone is not a native pass.\n", stderr)
            exit(77)
        }
        nativeTests()
        print("PASS: \(checks) total window-placement checks, including isolated native autosave/restore")
    }

    private static func geometryTests() {
        let minimum = CGSize(width: 860, height: 540)
        let main = CGRect(x: 0, y: 23, width: 1440, height: 877)
        let external = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let normal = CGRect(x: 100, y: 100, width: 1180, height: 760)
        let smaller = CGRect(x: 31, y: 45, width: 860, height: 540)
        expect(WindowPlacement.reachableFrame(normal, visibleFrames: [main], minimumSize: minimum) == normal,
               "saved larger size and noncentered origin remain unchanged")
        expect(WindowPlacement.reachableFrame(smaller, visibleFrames: [main], minimumSize: minimum) == smaller,
               "saved smaller size and noncentered origin remain unchanged")
        let negative = CGRect(x: -1800, y: 140, width: 1180, height: 760)
        expect(WindowPlacement.reachableFrame(negative, visibleFrames: [main,external], minimumSize: minimum) == negative,
               "negative-origin external monitor remains a valid destination")
        let spanning = CGRect(x: -800, y: 100, width: 1800, height: 760)
        expect(WindowPlacement.reachableFrame(spanning, visibleFrames: [main,external], minimumSize: minimum) == spanning,
               "reachable window intentionally spanning monitors is preserved")
        let partial = CGRect(x: -100, y: 100, width: 860, height: 540)
        expect(WindowPlacement.reachableFrame(partial, visibleFrames: [main], minimumSize: minimum) == partial,
               "partly offscreen window with reachable title bar is preserved")
        let barely = CGRect(x: -840, y: 100, width: 860, height: 540)
        let repaired = WindowPlacement.reachableFrame(barely, visibleFrames: [main], minimumSize: minimum)!
        expect(main.contains(repaired) && repaired.size == barely.size, "inaccessible title bar is recovered without unnecessary resizing")
        let removed = CGRect(x: 1800, y: 200, width: 1180, height: 760)
        let recovered = WindowPlacement.reachableFrame(removed, visibleFrames: [main], minimumSize: minimum)!
        expect(main.contains(recovered), "removed monitor cannot leave the window unreachable")
        expect(recovered.size == removed.size, "removed monitor preserves a size that still fits")
        let oversized = WindowPlacement.reachableFrame(CGRect(x:-500,y:-500,width:5000,height:3000), visibleFrames:[main], minimumSize:minimum)!
        expect(oversized == main, "oversized frame is reduced only to the available screen")
        let grown = WindowPlacement.reachableFrame(CGRect(x:100,y:100,width:300,height:200), visibleFrames:[main], minimumSize:minimum)!
        expect(grown.size == minimum && grown.origin == CGPoint(x:100,y:100), "old small frames respect the current minimum without recentering")
        let tiny = CGRect(x:0,y:0,width:640,height:400)
        expect(WindowPlacement.reachableFrame(normal, visibleFrames:[tiny], minimumSize:minimum) == tiny,
               "smaller display wins over an impossible minimum so the title bar stays accessible")
        let left = CGRect(x:0,y:0,width:1280,height:800), right = CGRect(x:1280,y:0,width:1280,height:800)
        let straddling = CGRect(x:1100,y:-530,width:900,height:540)
        let mostOverlap = WindowPlacement.reachableFrame(straddling, visibleFrames:[left,right], minimumSize:minimum)!
        expect(right.contains(mostOverlap), "recovery prefers the screen with greatest surviving intersection")
        let far = CGRect(x:3000,y:100,width:860,height:540)
        expect(right.contains(WindowPlacement.reachableFrame(far, visibleFrames:[left,right], minimumSize:minimum)!),
               "removed monitor fallback chooses the nearest remaining screen")
        expect(WindowPlacement.reachableFrame(negative, visibleFrames:[], minimumSize:minimum) == negative,
               "no-screen geometry query preserves a valid frame without using global display state")
        expect(WindowPlacement.reachableFrame(normal, visibleFrames:[.null,.zero], minimumSize:minimum) == normal,
               "invalid screen rectangles are ignored")
        for invalid in [CGRect.zero, CGRect(x:0,y:0,width:-1,height:10), CGRect(x:0,y:0,width:10,height:-1),
                        CGRect(x:CGFloat.nan,y:0,width:100,height:100), CGRect(x:0,y:CGFloat.infinity,width:100,height:100),
                        CGRect(x:0,y:0,width:CGFloat.infinity,height:100), CGRect.null] {
            expect(WindowPlacement.reachableFrame(invalid, visibleFrames:[main], minimumSize:minimum) == nil,
                   "invalid saved geometry is rejected")
        }
        expect(WindowPlacement.reachableFrame(normal, visibleFrames:[main], minimumSize:CGSize(width:CGFloat.nan,height:-1)) == normal,
               "invalid minimum values do not corrupt valid placement")
    }

    private static func nativeTests() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let name = "LanternWindowPlacement.Tests.\(UUID().uuidString)"
        let key = "NSWindow Frame \(name)"
        expect(name != WindowPlacement.autosaveName && UserDefaults.standard.object(forKey:key) == nil,
               "native test owns a fresh UUID autosave key")
        defer {
            NSWindow.removeFrame(usingName:name)
            UserDefaults.standard.removeObject(forKey:key)
        }
        func makeWindow() -> PlacementProbeWindow {
            let window = PlacementProbeWindow(contentRect:NSRect(x:0,y:0,width:500,height:320),
                styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
            window.isReleasedWhenClosed=false;window.minSize=NSSize(width:200,height:120)
            return window
        }
        let first=makeWindow()
        expect(!first.isVisible && !first.isKeyWindow && first.frameAutosaveName.isEmpty,"fresh native test window is invisible, inactive, and unregistered")
        expect(!WindowPlacement.restoreAndRegister(first,name:name),"missing saved frame uses first-launch placement")
        expect(first.centerCalls == 1 && first.frameAutosaveName == name,"first launch centers once, then registers native autosave")
        let screen = first.screen?.visibleFrame ?? NSScreen.screens[0].visibleFrame
        let sizes = [CGSize(width:min(860,screen.width-60),height:min(540,screen.height-60)),
                     CGSize(width:min(1180,screen.width-30),height:min(760,screen.height-30))]
        let firstFrame=CGRect(x:screen.minX+17,y:screen.minY+19,width:sizes[0].width,height:sizes[0].height)
        first.setFrame(firstFrame,display:false)
        let actualFirst=first.frame
        WindowPlacement.save(first)
        expect(UserDefaults.standard.string(forKey:key) != nil,"native helper writes only its registered owned frame name")
        close(first)

        let second=makeWindow()
        second.setContentSize(NSSize(width:620,height:410)) // Simulate initial UI setup before restoration.
        expect(second.frameAutosaveName.isEmpty,"UI setup does not register autosave before reading previous placement")
        expect(WindowPlacement.restoreAndRegister(second,name:name),"saved first size restores after initial UI setup")
        expect(second.frame == actualFirst,"native restore preserves first size and noncentered origin")
        expect(second.centerCalls == 0,"successful restore never calls center")
        expect(second.frameAutosaveName == name,"restored window registers future native autosave")
        let secondFrame=CGRect(x:screen.minX+11,y:screen.minY+13,width:sizes[1].width,height:sizes[1].height)
        second.setFrame(secondFrame,display:false)
        let actualSecond=second.frame
        let beforeSave=second.saveCalls
        WindowPlacement.save(second)
        expect(second.saveCalls == beforeSave+1,"registered ordinary window saves explicitly")
        let savedNormal=UserDefaults.standard.string(forKey:key)
        let beforeFullScreen=second.saveCalls
        second.pretendFullScreen=true
        WindowPlacement.save(second)
        second.pretendFullScreen=false
        expect(second.saveCalls == beforeFullScreen && UserDefaults.standard.string(forKey:key) == savedNormal,
               "fullscreen guard never saves transient fullscreen geometry")
        close(second)

        let third=makeWindow()
        expect(WindowPlacement.restoreAndRegister(third,name:name),"most recently adjusted frame restores on another launch")
        expect(third.frame == actualSecond && third.frame != actualFirst,"native restore remembers the second adjusted size and position")
        expect(third.centerCalls == 0 && !third.isVisible && !third.isKeyWindow,"restoration stays invisible and never recenters or activates the window")
        close(third)
        let unregistered=makeWindow()
        let unusedSaveCount=unregistered.saveCalls
        WindowPlacement.save(unregistered)
        expect(unregistered.saveCalls == unusedSaveCount,"headless unregistered windows never write frame preferences")
        close(unregistered)
        print("Native autosave sizes checked: \(Int(actualFirst.width))×\(Int(actualFirst.height)), \(Int(actualSecond.width))×\(Int(actualSecond.height)); no visible windows or production frame keys used.")
    }
}
