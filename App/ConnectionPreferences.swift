// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

struct ConnectionPreferences: Equatable {
    var zoomMode: DesktopZoomMode
    var qualityIndex: Int

    init(zoomMode: DesktopZoomMode = .fit, qualityIndex: Int = 3) {
        self.zoomMode = zoomMode
        self.qualityIndex = qualityIndex
    }
}

/// Display/quality choices only. Device profiles and Keychain credentials are
/// deliberately separate. Each endpoint's DTO is independently encoded JSON.
final class ConnectionPreferencesStore {
    private static let storageKey = "connectionPreferences.v1"
    private let defaults: UserDefaults

    private struct Entry: Codable {
        var kind: String
        var scale: Double?
        var qualityIndex: Int

        var preferences: ConnectionPreferences {
            let zoom: DesktopZoomMode
            switch kind {
            case "automatic": zoom = .automatic
            case "fit": zoom = .fit
            case "scale":
                if let scale = scale, scale.isFinite { zoom = .scale(max(0.1, min(4, scale))) }
                else { zoom = .fit }
            default: zoom = .fit
            }
            return ConnectionPreferences(zoomMode: zoom, qualityIndex: max(0, min(3, qualityIndex)))
        }
    }

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// A legacy quality is an explicit fallback for an endpoint without a saved
    /// entry. Loading never copies a global preference or writes a migration.
    func load(host: String, port: UInt16, legacyQuality: Int? = nil) -> ConnectionPreferences {
        guard let key = Self.endpointKey(host: host, port: port) else { return ConnectionPreferences() }
        let missing = ConnectionPreferences(qualityIndex: legacyQuality.map { max(0, min(3, $0)) } ?? 3)
        guard let object = defaults.object(forKey: Self.storageKey) else { return missing }
        guard let entries = object as? [String: Any] else { return ConnectionPreferences() }
        guard let object = entries[key] else { return missing }
        guard let data = object as? Data, let entry = try? JSONDecoder().decode(Entry.self, from: data) else {
            return ConnectionPreferences()
        }
        return entry.preferences
    }

    @discardableResult
    func save(host: String, port: UInt16, zoomMode: DesktopZoomMode, qualityIndex: Int) -> Bool {
        guard let key = Self.endpointKey(host: host, port: port) else { return false }
        let entry: Entry
        let quality = max(0, min(3, qualityIndex))
        switch zoomMode {
        case .fit: entry = Entry(kind: "fit", scale: nil, qualityIndex: quality)
        case .automatic: entry = Entry(kind: "automatic", scale: nil, qualityIndex: quality)
        case .scale(let value):
            guard value.isFinite else { return false }
            entry = Entry(kind: "scale", scale: max(0.1, min(4, value)), qualityIndex: quality)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(entry) else { return false }
        var entries = defaults.dictionary(forKey: Self.storageKey) ?? [:]
        entries[key] = data
        defaults.set(entries, forKey: Self.storageKey)
        return true
    }

    @discardableResult
    func remove(host: String, port: UInt16) -> Bool {
        guard let key = Self.endpointKey(host: host, port: port) else { return false }
        guard var entries = defaults.dictionary(forKey: Self.storageKey), entries.removeValue(forKey: key) != nil else {
            return true
        }
        if entries.isEmpty { defaults.removeObject(forKey: Self.storageKey) }
        else { defaults.set(entries, forKey: Self.storageKey) }
        return true
    }

    /// Same trimmed/case-folded, bracket-normalized endpoint identity used by
    /// password storage, without a Security dependency or network resolution.
    static func endpointKey(host: String, port: UInt16) -> String? {
        guard port > 0 else { return nil }
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        var address = trimmed.precomposedStringWithCanonicalMapping
            .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
        guard !address.isEmpty, address.utf8.count <= 255,
              address.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        if address.hasPrefix("[") && address.hasSuffix("]") {
            address = String(address.dropFirst().dropLast())
            guard address.contains(":") else { return nil }
        }
        if address.contains(":") {
            let scoped = address.split(separator: "%", omittingEmptySubsequences: false)
            guard scoped.count == 1 || (scoped.count == 2 && !scoped[1].isEmpty &&
                  scoped[1].unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "_.-".unicodeScalars.contains($0) })) else { return nil }
            guard validIPv6(String(scoped[0])) else { return nil }
        } else {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
            guard address.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
            let plain = address.hasSuffix(".") ? String(address.dropLast()) : address
            let labels = plain.split(separator: ".", omittingEmptySubsequences: false)
            guard !labels.isEmpty, labels.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 63 &&
                  !$0.hasPrefix("-") && !$0.hasSuffix("-") }) else { return nil }
            if address.contains(".") && address.allSatisfy({ "0123456789.".contains($0) }) {
                guard labels.count == 4, labels.allSatisfy({ UInt8($0) != nil }) else { return nil }
            }
        }
        return "v1|\(address.utf8.count)|\(address)|\(port)"
    }

    private static func validIPv6(_ address: String) -> Bool {
        let compressed = address.components(separatedBy: "::")
        guard compressed.count <= 2 else { return false }
        let tokens: [String]
        if compressed.count == 2 {
            let left = compressed[0].isEmpty ? [] : compressed[0].components(separatedBy: ":")
            let right = compressed[1].isEmpty ? [] : compressed[1].components(separatedBy: ":")
            tokens = left + right
        } else { tokens = address.components(separatedBy: ":") }
        var units = 0
        for (index, token) in tokens.enumerated() {
            if token.contains(".") {
                guard index == tokens.count - 1, address.hasSuffix(token) else { return false }
                let octets = token.split(separator: ".", omittingEmptySubsequences: false)
                guard octets.count == 4, octets.allSatisfy({ !$0.isEmpty && UInt8($0) != nil &&
                      $0.allSatisfy({ "0123456789".contains($0) }) && ($0.count == 1 || !$0.hasPrefix("0")) }) else { return false }
                units += 2
            } else {
                guard !token.isEmpty, token.count <= 4,
                      token.allSatisfy({ "0123456789abcdef".contains($0) }) else { return false }
                units += 1
            }
        }
        return compressed.count == 2 ? units < 8 : units == 8
    }
}
