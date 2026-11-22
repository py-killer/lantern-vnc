// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit

@main
struct ScreenCardsHarness {
    static var checks=0
    static func expect(_ value:@autoclosure()->Bool,_ message:String) {
        checks+=1
        if !value() { fatalError("Screen cards: \(message)") }
    }
    static func descendants(_ view:NSView)->[NSView] { [view]+view.subviews.flatMap(descendants) }
    static func main() throws {
        let application=NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let window=NSWindow(contentRect:NSRect(x:-12000,y:-12000,width:288,height:500),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.ignoresMouseEvents=true
        defer { window.close() }
        let root=window.contentView!
        let title="Office computer with a long descriptive name that must truncate"
        let card=ScreenCardView(identifier:"owned-test",title:title,kind:.computer)
        card.translatesAutoresizingMaskIntoConstraints=false;root.addSubview(card)
        NSLayoutConstraint.activate([card.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:22),card.topAnchor.constraint(equalTo:root.topAnchor,constant:12),card.widthAnchor.constraint(equalToConstant:244)])
        root.layoutSubtreeIfNeeded()
        expect(card.frame.width==244 && card.frame.maxX<=root.bounds.maxX,"card fits 288-point sidebar")
        expect(card.frame.height>180 && card.frame.height<205,"compact card height")
        expect(card.accessibilityRole() == .button,"one accessible selection button")
        expect(card.accessibilityLabel()?.contains(title)==true,"full truncated title remains accessible")
        let preview=descendants(card).first{$0.identifier?.rawValue=="screenCardPreview.owned-test"} as! NSImageView
        expect(abs(preview.bounds.height-preview.bounds.width*9.0/16.0)<=0.5,"thumbnail viewport is 16:9 within AppKit pixel rounding")
        expect(preview.imageScaling == .scaleProportionallyUpOrDown && preview.imageAlignment == .alignCenter,"source aspect is centered and letterboxed")
        for child in descendants(card) {
            expect(child.frame.width.isFinite && child.frame.height.isFinite && child.frame.width>=0 && child.frame.height>=0,"all layout frames finite/nonnegative")
        }
        var selected=0,edited=0,removed=0,disconnected=0
        card.onSelect={selected+=1};card.onEdit={edited+=1};card.onRemove={removed+=1};card.onDisconnect={disconnected+=1}
        expect(card.accessibilityPerformPress(),"accessibility press accepted")
        expect(selected==1 && edited==0 && removed==0 && disconnected==0,"one accessibility press only selects once")
        let click=NSEvent.mouseEvent(with:.leftMouseDown,location:NSPoint(x:30,y:30),modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
        card.mouseDown(with:click)
        expect(selected==2,"one mouse click selects exactly once")
        let space=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,characters:" ",charactersIgnoringModifiers:" ",isARepeat:false,keyCode:49)!
        card.keyDown(with:space)
        expect(selected==3,"space activates focused local card")
        let repeated=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,characters:" ",charactersIgnoringModifiers:" ",isARepeat:true,keyCode:49)!
        card.keyDown(with:repeated)
        expect(selected==3,"holding space does not repeat selection")
        let menu=card.menu(for:click)!
        expect(menu.items.map{$0.title} == ["Rename…","Disconnect","Remove"],"only configured context actions are available")
        for item in menu.items { expect(application.sendAction(item.action!,to:item.target,from:item),"owned context action delivered") }
        expect(edited==1 && removed==1 && disconnected==1 && selected==3,"context actions never trigger selection or extra actions")
        card.onEdit=nil;card.onDisconnect=nil
        expect(card.menu(for:click)?.items.map{$0.title} == ["Remove"],"optional menu actions disappear")
        let sampler=ScreenPreviewSampler()
        var sampleBytes=[UInt8]()
        for y in 0..<120 { for x in 0..<60 {
            sampleBytes += x<30 ? [UInt8(150),190,35,0] : [UInt8(230),110,55,0]
            if y==60 { sampleBytes.replaceSubrange((sampleBytes.count-4)..<sampleBytes.count,with:[255,255,255,0]) }
        } }
        let sampled=sampleBytes.withUnsafeBufferPointer { sampler.sample($0.baseAddress!,width:60,height:120,stride:240,now:0)! }
        let image=NSImage(cgImage:sampled.cgImage,size:NSSize(width:60,height:120))
        card.update(title:"Renamed",status:"Connected · preview updated recently",image:image,selected:true)
        expect(card.isSelected && preview.image === image,"update selects card and supplies memory-only image")
        expect((card.accessibilityValue() as? String)?.contains("Selected.")==true,"selection is exposed to accessibility")
        expect((card.accessibilityValue() as? String)?.contains("updated recently")==true,"status/age is accessible")
        expect(card.accessibilityLabel()?.contains("Renamed")==true,"renamed accessibility label updates")
        // The invisible layered view may already have pending display work.
        // Observe NEW invalidation/mutation requests instead of assuming that
        // assigning needsDisplay=false flushes AppKit's dirty-region state.
        var invalidations=0,imageChanges=0
        let displayObservation=card.observe(\.needsDisplay,options:[.new]) { _,_ in invalidations += 1 }
        let imageObservation=preview.observe(\.image,options:[.new]) { _,_ in imageChanges += 1 }
        card.update(title:"Renamed",status:"Connected · preview updated recently",image:image,selected:true)
        expect(invalidations == 0 && imageChanges == 0,"unchanged selected card requests no new invalidation or image mutation")
        let replacementImage=NSImage(cgImage:sampled.cgImage,size:NSSize(width:60,height:120))
        card.update(title:"Renamed",status:"Connected · preview updated recently",image:replacementImage,selected:true)
        expect(invalidations > 0 && imageChanges > 0 && preview.image === replacementImage,"a new thumbnail updates the image and requests display work")
        displayObservation.invalidate();imageObservation.invalidate()
        card.update(title:"Renamed",status:"Connected · preview updated recently",image:image,selected:true)
        if CommandLine.arguments.count>1 {
            card.update(title:"Office computer",status:"Connected · updated 2s ago",image:image,selected:true)
            card.updateLayer();card.displayIfNeeded()
            guard let bitmap=card.bitmapImageRepForCachingDisplay(in:card.bounds) else {
                fputs("UNAVAILABLE: offscreen AppKit rendering is unavailable (exit77).\n",stderr);exit(77)
            }
            card.cacheDisplay(in:card.bounds,to:bitmap)
            guard let png=bitmap.representation(using:.png,properties:[:]) else { fatalError("PNG encoding unavailable") }
            try png.write(to:URL(fileURLWithPath:CommandLine.arguments[1]),options:.atomic)
        }
        card.isEnabled=false
        expect(!card.accessibilityPerformPress(),"disabled card rejects accessibility action")
        card.mouseDown(with:click);expect(selected==3,"disabled card rejects mouse action")
        expect(card.menu(for:click)?.items.allSatisfy{!$0.isEnabled}==true,"disabled context actions cannot run")
        let browser=ScreenCardView(identifier:"browser-test",title:"Saved documentation",kind:.browser)
        expect(browser.accessibilityLabel()?.contains("browser window")==true,"browser card is identified as a browser window")
        expect(browser.menu(for:click)==nil,"unconfigured card has no context actions")
        browser.onEdit={}
        expect(browser.menu(for:click)?.items.first?.title=="Edit…","browser context action edits its saved page")
        expect(!window.isKeyWindow && !window.isVisible,"owned test window never shown or activated")
        print("PASS: \(checks) screen-card native layout/accessibility/local-action checks; no visible windows, global input, network or credentials")
    }
}
