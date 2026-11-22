// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

struct BrowserScreen: Codable, Equatable {
    let id: String
    var title: String
    var url: String
}

enum BrowserScreenError: LocalizedError {
    case invalidURL, unsupportedScheme, embeddedCredentials, limitReached
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Use a valid website address and TCP port."
        case .unsupportedScheme: return "Browser screens support HTTP and HTTPS addresses."
        case .embeddedCredentials: return "Website addresses containing a username or password cannot be saved."
        case .limitReached: return "The browser-screen list is full. Remove an unused screen first."
        }
    }
}

/// Browser cards are separate from VNC devices and contain no imported browser
/// data or credentials. Cookies belong to WebKit's app-local website data store.
final class BrowserScreenStore {
    static let maximumScreens = 100
    private static let key = "browserScreens.v1"
    private let defaults: UserDefaults
    private(set) var screens: [BrowserScreen] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: Self.key),
              let saved = try? JSONDecoder().decode([BrowserScreen].self, from: data) else { return }
        var ids = Set<String>()
        for screen in saved {
            guard screens.count < Self.maximumScreens, UUID(uuidString: screen.id) != nil,
                  !ids.contains(screen.id), let url = try? Self.sanitizedURL(screen.url) else { continue }
            ids.insert(screen.id)
            screens.append(BrowserScreen(id: screen.id, title: Self.cleanTitle(screen.title, fallback: url.host ?? "Web page"), url: url.absoluteString))
        }
    }

    @discardableResult
    func add(title: String, url: String) throws -> BrowserScreen {
        guard screens.count < Self.maximumScreens else { throw BrowserScreenError.limitReached }
        let address = try Self.sanitizedURL(url)
        let screen = BrowserScreen(id: UUID().uuidString, title: Self.cleanTitle(title, fallback: address.host ?? "Web page"), url: address.absoluteString)
        screens.append(screen); persist(); return screen
    }
    @discardableResult
    func update(id: String, title: String? = nil, url: String? = nil) throws -> BrowserScreen? {
        guard let index = screens.firstIndex(where: { $0.id == id }) else { return nil }
        let address = try Self.sanitizedURL(url ?? screens[index].url)
        let updated = BrowserScreen(id: id, title: Self.cleanTitle(title ?? screens[index].title, fallback: address.host ?? "Web page"), url: address.absoluteString)
        screens[index] = updated; persist(); return updated
    }
    func remove(id: String) {
        guard screens.contains(where: { $0.id == id }) else { return }
        screens.removeAll { $0.id == id }; persist()
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
    private func persist() {
        if let data = try? JSONEncoder().encode(screens) { defaults.set(data, forKey: Self.key) }
    }
}
