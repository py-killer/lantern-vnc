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
        expect(local.url == "http://192.168.0.101:8080/dashboard" && local.title == "192.168.0.101","LAN ports work and default titles omit paths or query data")
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
        expect(blank.title == "fallback.example" && !blank.title.contains("token"),"fallback titles never expose URL query values")
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
        print("PASS: \(checks) browser-card persistence, URL validation, resource bounds and isolation checks")
    }
}
