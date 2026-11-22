// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

struct BrowserTab: Codable, Equatable {
    let id: String
    var title: String
    /// Empty is an explicit new-tab state, never an arbitrary URL scheme.
    var url: String
}

struct BrowserScreen: Codable, Equatable {
    let id: String
    /// The workspace alias is independent of individual website titles.
    var title: String
    var tabs: [BrowserTab]
    var selectedTabID: String
    /// nil keeps the existing in-app WebKit window. Installed browsers retain
    /// their own profiles/extensions; Lantern never imports that data.
    var browserBundleIdentifier: String?
    var selectedTab: BrowserTab? { tabs.first { $0.id == selectedTabID } ?? tabs.first }
    /// Compatibility for existing card/navigation callers.
    var url: String { selectedTab?.url ?? "" }

    init(id: String, title: String, url: String, browserBundleIdentifier: String? = nil) {
        let tab=BrowserTab(id:UUID().uuidString,title:title,url:url)
        self.init(id:id,title:title,tabs:[tab],selectedTabID:tab.id,browserBundleIdentifier:browserBundleIdentifier)
    }
    init(id: String, title: String, tabs: [BrowserTab], selectedTabID: String, browserBundleIdentifier: String? = nil) {
        self.id=id;self.title=title;self.tabs=tabs;self.selectedTabID=selectedTabID
        self.browserBundleIdentifier=browserBundleIdentifier
    }
    private enum CodingKeys: String, CodingKey { case id,title,url,tabs,selectedTabID,browserBundleIdentifier }
    init(from decoder: Decoder) throws {
        let values=try decoder.container(keyedBy:CodingKeys.self)
        id=try values.decode(String.self,forKey:.id)
        title=(try? values.decode(String.self,forKey:.title)) ?? ""
        browserBundleIdentifier=try values.decodeIfPresent(String.self,forKey:.browserBundleIdentifier)
        try BrowserScreenStore.validateBrowser(browserBundleIdentifier)
        if values.contains(.tabs) {
            tabs=try values.decode([LossyBrowserValue<BrowserTab>].self,forKey:.tabs).compactMap(\.value)
            selectedTabID=(try? values.decode(String.self,forKey:.selectedTabID)) ?? tabs.first?.id ?? ""
        } else {
            let address=try BrowserScreenStore.sanitizedURL(values.decode(String.self,forKey:.url)).absoluteString
            let tab=BrowserTab(id:UUID().uuidString,title:title,url:address)
            tabs=[tab];selectedTabID=tab.id
        }
    }
    func encode(to encoder: Encoder) throws {
        var values=encoder.container(keyedBy:CodingKeys.self)
        try values.encode(id,forKey:.id);try values.encode(title,forKey:.title)
        try values.encode(url,forKey:.url);try values.encode(tabs,forKey:.tabs)
        try values.encode(selectedTabID,forKey:.selectedTabID)
        try values.encodeIfPresent(browserBundleIdentifier,forKey:.browserBundleIdentifier)
    }
}

/// A malformed record does not discard neighboring valid workspaces/tabs.
private struct LossyBrowserValue<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value=try? Value(from:decoder) }
}

enum BrowserScreenError: LocalizedError {
    case invalidURL, unsupportedScheme, embeddedCredentials, limitReached, invalidTabs, tabLimitReached, unsupportedBrowser
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Use a valid website address and TCP port."
        case .unsupportedScheme: return "Browser screens support HTTP and HTTPS addresses."
        case .embeddedCredentials: return "Website addresses containing a username or password cannot be saved."
        case .limitReached: return "The browser-screen list is full. Remove an unused screen first."
        case .invalidTabs: return "Keep at least one valid tab and select a tab in this browser window."
        case .tabLimitReached: return "A browser window can keep up to 12 tabs. Close an unused tab first."
        case .unsupportedBrowser: return "Choose Safari, Google Chrome, or the browser inside Lantern."
        }
    }
}

/// Browser cards are separate from VNC devices and contain no imported browser
/// data or credentials. Cookies belong to WebKit's app-local website data store.
final class BrowserScreenStore {
    static let maximumScreens = 100
    static let maximumTabsPerScreen = 12
    private static let key = "browserScreens.v1"
    private let defaults: UserDefaults
    private(set) var screens: [BrowserScreen] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: Self.key),
              let saved = try? JSONDecoder().decode([LossyBrowserValue<BrowserScreen>].self, from: data) else { return }
        var ids = Set<UUID>()
        for screen in saved.compactMap(\.value) {
            guard screens.count < Self.maximumScreens,let identity=UUID(uuidString:screen.id),!ids.contains(identity),
                  let state=try? Self.validatedTabs(screen.tabs,selectedTabID:screen.selectedTabID,recovering:true),
                  screen.browserBundleIdentifier == nil || state.tabs.first(where:{$0.id == state.selected})?.url.isEmpty == false else { continue }
            ids.insert(identity)
            let fallback=state.tabs.first(where:{$0.id == state.selected})
                .flatMap { URL(string:$0.url)?.host } ?? "Browser window"
            screens.append(BrowserScreen(id:screen.id,title:Self.cleanTitle(screen.title,fallback:fallback),tabs:state.tabs,selectedTabID:state.selected,browserBundleIdentifier:screen.browserBundleIdentifier))
        }
        // Persist generated legacy tab IDs and repaired selections once, so a
        // second launch restores the same tab identities instead of remigrating.
        persist()
    }

    @discardableResult
    func add(title: String, url: String, browserBundleIdentifier: String? = nil) throws -> BrowserScreen {
        guard screens.count < Self.maximumScreens else { throw BrowserScreenError.limitReached }
        try Self.validateBrowser(browserBundleIdentifier)
        let address = try Self.sanitizedURL(url)
        let screen = BrowserScreen(id: UUID().uuidString, title: Self.cleanTitle(title, fallback: "Browser \(screens.count+1)"), url: address.absoluteString,browserBundleIdentifier:browserBundleIdentifier)
        screens.append(screen); persist(); return screen
    }
    @discardableResult
    func add(title: String, tabs: [BrowserTab], selectedTabID: String, browserBundleIdentifier: String? = nil) throws -> BrowserScreen {
        guard screens.count < Self.maximumScreens else { throw BrowserScreenError.limitReached }
        try Self.validateBrowser(browserBundleIdentifier)
        let state=try Self.validatedTabs(tabs,selectedTabID:selectedTabID)
        if browserBundleIdentifier != nil, state.tabs.first(where:{$0.id == state.selected})?.url.isEmpty != false { throw BrowserScreenError.invalidURL }
        let screen=BrowserScreen(id:UUID().uuidString,title:Self.cleanTitle(title,fallback:"Browser \(screens.count+1)"),tabs:state.tabs,selectedTabID:state.selected,browserBundleIdentifier:browserBundleIdentifier)
        screens.append(screen);persist();return screen
    }
    @discardableResult
    func update(id: String, title: String? = nil, url: String? = nil) throws -> BrowserScreen? {
        guard let index = screens.firstIndex(where: { $0.id == id }) else { return nil }
        var updated=screens[index]
        if let raw=url {
            let address=try Self.sanitizedURL(raw)
            guard let selected=updated.tabs.firstIndex(where:{$0.id == updated.selectedTabID}) else { throw BrowserScreenError.invalidTabs }
            updated.tabs[selected].url=address.absoluteString
        }
        if let title=title { updated.title=Self.cleanTitle(title,fallback:URL(string:updated.url)?.host ?? "Browser window") }
        screens[index] = updated; persist(); return updated
    }
    @discardableResult
    func updateTabs(id: String, tabs: [BrowserTab], selectedTabID: String) throws -> BrowserScreen? {
        guard let index=screens.firstIndex(where:{$0.id == id}) else { return nil }
        let state=try Self.validatedTabs(tabs,selectedTabID:selectedTabID)
        if screens[index].browserBundleIdentifier != nil, state.tabs.first(where:{$0.id == state.selected})?.url.isEmpty != false { throw BrowserScreenError.invalidURL }
        var updated=screens[index];updated.tabs=state.tabs;updated.selectedTabID=state.selected
        screens[index]=updated;persist();return updated
    }
    func remove(id: String) {
        guard screens.contains(where: { $0.id == id }) else { return }
        screens.removeAll { $0.id == id }; persist()
    }

    private static func validatedTabs(_ tabs: [BrowserTab],selectedTabID: String,recovering: Bool=false) throws -> (tabs:[BrowserTab],selected:String) {
        guard tabs.count <= maximumTabsPerScreen else { throw BrowserScreenError.tabLimitReached }
        var valid:[BrowserTab]=[],ids=Set<UUID>()
        for tab in tabs {
            guard let identity=UUID(uuidString:tab.id),!ids.contains(identity) else {
                if recovering { continue };throw BrowserScreenError.invalidTabs
            }
            let address:String
            do { address=tab.url.isEmpty ? "" : try sanitizedURL(tab.url).absoluteString }
            catch { if recovering { continue };throw error }
            let fallback=address.isEmpty ? "New tab" : URL(string:address)?.host ?? "Web page"
            valid.append(BrowserTab(id:tab.id,title:cleanTitle(tab.title,fallback:fallback),url:address));ids.insert(identity)
        }
        guard !valid.isEmpty else { throw BrowserScreenError.invalidTabs }
        if valid.contains(where:{$0.id == selectedTabID}) { return (valid,selectedTabID) }
        if recovering { return (valid,valid[0].id) }
        throw BrowserScreenError.invalidTabs
    }

    /// A bare public hostname defaults to HTTPS. Local/single-label hosts,
    /// private IPv4 addresses, IPv6 literals and explicit ports default to HTTP.
    /// No DNS lookup or network connection is performed during validation.
    static func sanitizedURL(_ value: String) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 8192,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !trimmed.contains("\\") else { throw BrowserScreenError.invalidURL }
        var candidate = trimmed
        if !candidate.contains("://") {
            let authority = String(candidate.prefix { !"/?#".contains($0) })
            guard !authority.contains("@") else { throw BrowserScreenError.embeddedCredentials }
            let hasPort = authority.hasPrefix("[") || (authority.split(separator: ":", omittingEmptySubsequences: false).count == 2 &&
                authority.split(separator: ":", omittingEmptySubsequences: false).last.map { !$0.isEmpty && $0.allSatisfy(\.isNumber) } == true)
            if authority.contains(":") && !hasPort { throw BrowserScreenError.unsupportedScheme }
            let host = authority.split(separator: ":").first.map(String.init)?.lowercased() ?? ""
            let octets = host.split(separator: ".").compactMap { UInt8($0) }
            let privateIPv4 = octets.count == 4 && (octets[0] == 10 || octets[0] == 127 ||
                (octets[0] == 192 && octets[1] == 168) || (octets[0] == 172 && (16...31).contains(octets[1])) ||
                (octets[0] == 169 && octets[1] == 254))
            let local = hasPort || !host.contains(".") || host.hasSuffix(".local") || privateIPv4
            candidate = (local ? "http://" : "https://") + candidate
        }
        guard let components = URLComponents(string: candidate), let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { throw BrowserScreenError.unsupportedScheme }
        guard components.user == nil && components.password == nil else { throw BrowserScreenError.embeddedCredentials }
        guard let host = components.host, !host.isEmpty,
              host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              host.rangeOfCharacter(from: .controlCharacters) == nil else { throw BrowserScreenError.invalidURL }
        let authority = candidate.components(separatedBy: "://").dropFirst().joined(separator: "://").prefix { !"/?#".contains($0) }
        guard !authority.hasSuffix(":"), components.port.map({ (1...65535).contains($0) }) ?? true,
              let url = components.url else { throw BrowserScreenError.invalidURL }
        return url
    }

    private static func cleanTitle(_ title: String, fallback: String) -> String {
        let plain = title.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
        let collapsed = plain.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.isEmpty ? fallback : String(collapsed.prefix(80))
    }
    static func validateBrowser(_ identifier:String?) throws {
        guard identifier == nil || identifier == "com.apple.Safari" || identifier == "com.google.Chrome" else {
            throw BrowserScreenError.unsupportedBrowser
        }
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(screens) { defaults.set(data, forKey: Self.key) }
    }
}
