// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

@main
struct BrowserStoreTests {
    private static var checks=0
    private static func expect(_ value: Bool,_ label: String) {
        checks += 1;guard value else { fatalError("Browser store test: \(label)") }
    }
    static func main() throws {
        let suite="LanternVNC.BrowserStoreTests.\(UUID().uuidString)"
        let otherSuite=suite+".isolated"
        let defaults=UserDefaults(suiteName:suite)!,otherDefaults=UserDefaults(suiteName:otherSuite)!
        defaults.removePersistentDomain(forName:suite);otherDefaults.removePersistentDomain(forName:otherSuite)
        defer { defaults.removePersistentDomain(forName:suite);otherDefaults.removePersistentDomain(forName:otherSuite) }
        defaults.set(Data([1,2,3]),forKey:"savedDevices.v1")
        let store=BrowserScreenStore(defaults:defaults)
        expect(store.screens.isEmpty,"browser cards start independently of VNC device records")
        let first=try store.add(title:"  Office\n tools  ",url:"  example.com/app?q=one#section  ")
        expect(UUID(uuidString:first.id) != nil,"card ID is a stable UUID")
        expect(first.title == "Office tools" && first.url == "https://example.com/app?q=one#section","title is clean and navigation URL preserves query and fragment")
        let local=try store.add(title:"",url:"192.168.0.101:8080/dashboard")
        expect(local.url == "http://192.168.0.101:8080/dashboard" && local.title == "Browser 2","LAN ports work and new untitled windows use a numbered alias")
        _=try store.add(title:"Local",url:"localhost:8081")
        _=try store.add(title:"Fourth",url:"https://fourth.example")
        expect(store.screens.count == 4,"browser list does not inherit the three-VNC-device limit")
        let reloaded=BrowserScreenStore(defaults:defaults)
        expect(reloaded.screens == store.screens,"restart preserves ordering, identifiers, aliases and URLs")
        let updated=try store.update(id:first.id,title:"Renamed",url:"https://example.com/next")
        expect(updated?.id == first.id && updated?.title == "Renamed" && store.screens[0].url == "https://example.com/next","editing a card preserves its identity and position")
        let before=store.screens
        do { _=try store.update(id:first.id,url:"https://name:secret@example.com/");fatalError("Credential URL accepted") }
        catch BrowserScreenError.embeddedCredentials { checks += 1 }
        expect(store.screens == before,"rejected edits do not partially modify or persist a card")
        expect(try store.update(id:UUID().uuidString,title:"Missing") == nil,"unknown card update is harmless")
        store.remove(id:local.id)
        expect(store.screens.count == 3 && !store.screens.contains { $0.id == local.id },"removal deletes only the requested browser card")
        store.remove(id:UUID().uuidString)
        expect(BrowserScreenStore(defaults:defaults).screens == store.screens,"removal persists and missing removal is harmless")
        expect(BrowserScreenStore(defaults:otherDefaults).screens.isEmpty,"independent preference stores never share cards")
        expect(defaults.data(forKey:"savedDevices.v1") == Data([1,2,3]),"VNC device records remain untouched")
        let accepted:[(String,String,String)] = [("https://example.com","https","example.com"),
            ("http://localhost:9000/a","http","localhost"),("printer.local/status","http","printer.local"),
            ("nas:8080/","http","nas"),("10.0.0.2/admin","http","10.0.0.2"),
            ("172.20.1.2","http","172.20.1.2"),("[::1]:8080/index","http","[::1]"),
            ("https://example.com:65535/a%20b?token=synthetic#route","https","example.com")]
        for (input,scheme,_) in accepted {
            let url=try BrowserScreenStore.sanitizedURL(input)
            expect(url.scheme?.lowercased() == scheme && url.host != nil,"valid HTTP(S)/LAN address is accepted")
            expect(url.user == nil && url.password == nil,"accepted address contains no embedded credentials")
        }
        for input in [""," ","javascript:alert(1)","data:text/html,test","file:///tmp/example","ftp://example.com","mailto:a@example.com",
                      "https://user@example.com","https://user:secret@example.com","http://:secret@localhost", "https://@example.com",
                      "http://example.com:0","http://example.com:65536","http://example.com:abc","http://example.com:",
                      "https:///path", "//example.com", "https://bad host/", "https://example.com/a\nb", "https://example.com/a\u{0}b",
                      "https:\\example.com",String(repeating:"a",count:8193)] {
            do { _=try BrowserScreenStore.sanitizedURL(input);fatalError("Browser store accepted invalid synthetic address") }
            catch is BrowserScreenError { checks += 1 }
        }
        let titled=try store.add(title:String(repeating:"x",count:200),url:"https://title.example/private?token=synthetic")
        expect(titled.title.count == 80,"long aliases have a bounded display length")
        let blank=try store.add(title:" \n\t",url:"https://fallback.example/private?token=synthetic")
        expect(blank.title.hasPrefix("Browser ") && !blank.title.contains("token"),"new default window aliases never expose URL query values")
        let valid=BrowserScreen(id:UUID().uuidString,title:"Valid",url:"https://valid.example")
        let malformed=[valid,valid,BrowserScreen(id:"not-a-uuid",title:"bad",url:"https://valid.example"),
                       BrowserScreen(id:UUID().uuidString,title:"bad",url:"https://user:synthetic@example.com")]
        otherDefaults.set(try JSONEncoder().encode(malformed),forKey:"browserScreens.v1")
        expect(BrowserScreenStore(defaults:otherDefaults).screens == [valid],"restart skips duplicate IDs, malformed IDs and credential-bearing URLs")
        otherDefaults.set(Data("broken".utf8),forKey:"browserScreens.v1")
        expect(BrowserScreenStore(defaults:otherDefaults).screens.isEmpty,"corrupt saved data is tolerated without inventing cards")
        let bounded=BrowserScreenStore(defaults:otherDefaults)
        for index in 0..<BrowserScreenStore.maximumScreens { _=try bounded.add(title:"Card \(index)",url:"https://example.com/\(index)") }
        do { _=try bounded.add(title:"Extra",url:"https://extra.example");fatalError("Resource bound ignored") }
        catch BrowserScreenError.limitReached { checks += 1 }
        expect(try bounded.update(id:bounded.screens[0].id,title:"Still editable")?.title == "Still editable","resource bound does not block editing an existing card")
        expect(bounded.screens.count == 100,"browser resource bound remains separate from VNC cap")

        // Decode actual old three-field JSON, not today's Codable encoder.
        otherDefaults.removePersistentDomain(forName:otherSuite)
        let legacyID=UUID().uuidString
        let legacy:[String:Any] = ["id":legacyID,"title":"Legacy tools","url":"https://legacy.example/path?q=synthetic#section"]
        otherDefaults.set(try JSONSerialization.data(withJSONObject:[legacy]),forKey:"browserScreens.v1")
        let migrated=BrowserScreenStore(defaults:otherDefaults)
        expect(migrated.screens.count == 1 && migrated.screens[0].id == legacyID && migrated.screens[0].title == "Legacy tools",
               "legacy migration preserves the existing card identity and alias")
        let legacyScreen=migrated.screens[0],legacyTab=legacyScreen.tabs[0]
        expect(legacyScreen.tabs.count == 1 && legacyTab.url == legacy["url"] as? String && legacyScreen.selectedTabID == legacyTab.id && UUID(uuidString:legacyTab.id) != nil,
               "legacy migration creates one selected UUID tab without changing its full URL")
        expect(BrowserScreenStore(defaults:otherDefaults).screens == migrated.screens,"legacy tab identities persist once instead of changing every restart")
        let encoded=try JSONSerialization.jsonObject(with:otherDefaults.data(forKey:"browserScreens.v1")!) as! [[String:Any]]
        expect(encoded[0]["url"] as? String == legacyScreen.url && (encoded[0]["tabs"] as? [[String:Any]])?.count == 1 && encoded[0]["selectedTabID"] as? String == legacyTab.id,
               "new encoding contains complete tabs, selected ID and compatible selected URL")
        let secondTab=BrowserTab(id:UUID().uuidString,title:"Second site",url:"http://localhost:8080/two")
        let thirdTab=BrowserTab(id:UUID().uuidString,title:"Third site",url:"https://third.example/three")
        let tabbed=try migrated.updateTabs(id:legacyID,tabs:[legacyTab,secondTab,thirdTab],selectedTabID:secondTab.id)!
        expect(tabbed.tabs == [legacyTab,secondTab,thirdTab] && tabbed.selectedTab == secondTab && tabbed.url == secondTab.url && tabbed.title == "Legacy tools",
               "selecting an internal tab preserves every tab and the separate workspace alias")
        let edited=try migrated.update(id:legacyID,title:"Renamed window",url:"https://selected.example/new?q=synthetic")!
        expect(edited.tabs.count == 3 && edited.tabs[0] == legacyTab && edited.tabs[2] == thirdTab && edited.tabs[1].id == secondTab.id && edited.tabs[1].title == secondTab.title,
               "legacy navigation update edits only the selected URL without replacing sibling tabs or titles")
        expect(edited.title == "Renamed window" && edited.url == "https://selected.example/new?q=synthetic" && edited.selectedTabID == secondTab.id,
               "workspace rename and selected navigation remain independent")
        expect(BrowserScreenStore(defaults:otherDefaults).screens == migrated.screens,"all internal tabs and selection survive reload")
        let reordered=try migrated.updateTabs(id:legacyID,tabs:[thirdTab,legacyTab,edited.tabs[1]],selectedTabID:thirdTab.id)!
        expect(reordered.tabs.map(\.id) == [thirdTab.id,legacyTab.id,secondTab.id] && reordered.selectedTabID == thirdTab.id,
               "tab reordering and selection preserve UUID identity and all saved URLs")
        let removedSelected=try migrated.updateTabs(id:legacyID,tabs:[legacyTab,edited.tabs[1]],selectedTabID:legacyTab.id)!
        expect(removedSelected.tabs.count == 2 && removedSelected.selectedTabID == legacyTab.id && removedSelected.title == "Renamed window",
               "closing selected tab persists its explicit surviving selection without renaming the window")

        func rejectedTabs(_ tabs:[BrowserTab],selected:String,label:String) {
            let before=migrated.screens,stored=otherDefaults.data(forKey:"browserScreens.v1")
            do { _=try migrated.updateTabs(id:legacyID,tabs:tabs,selectedTabID:selected);fatalError("Accepted invalid tab state: "+label) }
            catch is BrowserScreenError { checks += 1 }
            catch { fatalError("Unexpected tab-state error") }
            expect(migrated.screens == before && otherDefaults.data(forKey:"browserScreens.v1") == stored,
                   "rejected state changes no in-memory or persisted sibling tab: "+label)
        }
        rejectedTabs([],selected:legacyTab.id,label:"last tab cannot disappear")
        rejectedTabs([legacyTab,legacyTab],selected:legacyTab.id,label:"duplicate IDs")
        rejectedTabs([legacyTab,BrowserTab(id:legacyTab.id.lowercased(),title:"Duplicate case",url:"https://other.example")],selected:legacyTab.id,label:"same UUID with different case")
        rejectedTabs([BrowserTab(id:"invalid-id",title:"Invalid",url:"https://example.com")],selected:"invalid-id",label:"malformed UUID")
        rejectedTabs([legacyTab],selected:UUID().uuidString,label:"selection outside window")
        rejectedTabs([legacyTab,BrowserTab(id:UUID().uuidString,title:"Unsafe",url:"javascript:alert(1)")],selected:legacyTab.id,label:"unsafe background URL")
        rejectedTabs([legacyTab,BrowserTab(id:UUID().uuidString,title:"Unsafe",url:"https://user:synthetic@example.com")],selected:legacyTab.id,label:"background embedded credentials")
        rejectedTabs([BrowserTab(id:UUID().uuidString,title:"Whitespace",url:" ")],selected:legacyTab.id,label:"whitespace is not the explicit blank sentinel")
        expect(try migrated.updateTabs(id:UUID().uuidString,tabs:[legacyTab],selectedTabID:legacyTab.id) == nil,
               "missing window update does not create another sidebar card")
        let newTab=BrowserTab(id:UUID().uuidString,title:"",url:"")
        let lastClosed=try migrated.updateTabs(id:legacyID,tabs:[newTab],selectedTabID:newTab.id)!
        expect(lastClosed.tabs.count == 1 && lastClosed.url.isEmpty && lastClosed.selectedTab?.title == "New tab" && lastClosed.selectedTabID != legacyTab.id,
               "closing last page can atomically replace it with a fresh explicit blank tab")
        expect(BrowserScreenStore(defaults:otherDefaults).screens == migrated.screens,"explicit blank tab and its selection survive restart without persisting about:blank")
        expect(try migrated.update(id:legacyID,title:"Blank workspace")?.url == "","renaming a blank workspace does not force a navigation")
        do { _=try migrated.update(id:legacyID,url:"");fatalError("Legacy empty URL accepted") }
        catch BrowserScreenError.invalidURL { checks += 1 }
        do { _=try BrowserScreenStore.sanitizedURL("");fatalError("URL validator accepted empty") }
        catch BrowserScreenError.invalidURL { checks += 1 }
        do { _=try migrated.add(title:"Invalid legacy blank",url:"");fatalError("Legacy blank add accepted") }
        catch BrowserScreenError.invalidURL { checks += 1 }
        let blankWindow=try migrated.add(title:"",tabs:[newTab],selectedTabID:newTab.id)
        expect(blankWindow.title == "Browser 2" && blankWindow.tabs.count == 1 && blankWindow.url.isEmpty,"explicit blank-window API uses a numbered alias and one safe tab")
        let twelve=(0..<BrowserScreenStore.maximumTabsPerScreen).map { BrowserTab(id:UUID().uuidString,title:"Site \($0)",url:"https://tabs.example/\($0)") }
        let atLimit=try migrated.updateTabs(id:legacyID,tabs:twelve,selectedTabID:twelve.last!.id)!
        expect(atLimit.tabs.count == 12 && atLimit.url == "https://tabs.example/11","all twelve tabs can be persisted with last tab selected")
        rejectedTabs(twelve+[BrowserTab(id:UUID().uuidString,title:"Extra",url:"https://extra.example")],selected:twelve[0].id,label:"thirteenth tab rejected without truncation")

        // Navigation/selection oracle: every nonselected DTO must remain exact.
        var oracle=twelve
        for step in 0..<48 {
            let selected=(step*7+3)%oracle.count
            _=try migrated.updateTabs(id:legacyID,tabs:oracle,selectedTabID:oracle[selected].id)
            oracle[selected].url="https://tabs.example/step/\(step)?tab=\(selected)"
            let actual=try migrated.update(id:legacyID,url:oracle[selected].url)!
            expect(actual.tabs == oracle && actual.selectedTabID == oracle[selected].id,"selection/navigation oracle preserves sibling tabs at step \(step)")
            expect(BrowserScreenStore(defaults:otherDefaults).screens.first{$0.id == legacyID} == actual,"complete tab state survives restart at step \(step)")
        }
        let cleaned=try migrated.updateTabs(id:legacyID,tabs:[BrowserTab(id:newTab.id,title:" \n\t",url:""),BrowserTab(id:thirdTab.id,title:String(repeating:"x",count:200),url:thirdTab.url)],selectedTabID:newTab.id)!
        expect(cleaned.tabs[0].title == "New tab" && cleaned.tabs[1].title.count == 80,"tab titles have safe blank fallback and bounded display length")

        // Mixed corruption is repaired per record/tab, never by trusting a
        // legacy URL when an explicitly supplied new tab state is malformed.
        let goodTab:[String:Any]=["id":legacyTab.id,"title":"Kept","url":"https://kept.example/full?q=synthetic#fragment"]
        let damaged:[String:Any]=["id":legacyID,"title":"Preserved alias","url":"https://ignored-legacy.example",
            "tabs":[goodTab,["id":"bad","title":"Bad","url":"https://bad.example"],goodTab,
                    ["id":UUID().uuidString,"title":"Unsafe","url":"https://name:synthetic@example.com"],["id":UUID().uuidString]],"selectedTabID":UUID().uuidString]
        let invalidNew:[String:Any]=["id":UUID().uuidString,"title":"Corrupt","url":"https://do-not-fallback.example","tabs":"invalid"]
        let emptyLegacy:[String:Any]=["id":UUID().uuidString,"title":"Invalid old blank","url":""]
        let oversize=BrowserScreen(id:UUID().uuidString,title:"Too many",tabs:twelve+[newTab],selectedTabID:twelve[0].id)
        let oversizedObject=try JSONSerialization.jsonObject(with:JSONEncoder().encode(oversize))
        otherDefaults.set(try JSONSerialization.data(withJSONObject:[damaged,invalidNew,emptyLegacy,oversizedObject,42]),forKey:"browserScreens.v1")
        let recovered=BrowserScreenStore(defaults:otherDefaults)
        expect(recovered.screens.count == 1 && recovered.screens[0].title == "Preserved alias" && recovered.screens[0].tabs.count == 1,
               "mixed malformed records, duplicate/unsafe tabs and oversized windows do not discard the neighboring valid workspace")
        expect(recovered.screens[0].selectedTabID == legacyTab.id && recovered.screens[0].url == goodTab["url"] as? String,
               "missing selection repairs deterministically to the surviving safe tab, preserving full URL")
        expect(BrowserScreenStore(defaults:otherDefaults).screens == recovered.screens,"recovered selection and cleaned tabs are stable across subsequent restarts")
        recovered.remove(id:legacyID)
        expect(BrowserScreenStore(defaults:otherDefaults).screens.isEmpty,"removing a tabbed workspace removes every saved internal tab")
        print("PASS: \(checks) browser-card persistence, URL validation, resource bounds and isolation checks")
    }
}
