// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

@main
struct ConnectionPreferencesTests {
    private static var checks = 0
    private static let storageKey = "connectionPreferences.v1"
    private static func expect(_ condition: Bool, _ label: String) {
        checks += 1
        guard condition else { fatalError("Connection preferences test: \(label)") }
    }

    static func main() throws {
        let suite = "LanternVNC.ConnectionPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ConnectionPreferencesStore(defaults: defaults)
        let initial = store.load(host: "example.invalid", port: 5900)
        expect(initial == ConnectionPreferences(zoomMode: .fit, qualityIndex: 3), "new connection defaults to Fit and Wi-Fi High Quality")
        expect(defaults.object(forKey: storageKey) == nil, "load is read-only")
        defaults.set(2, forKey: "quality")
        expect(store.load(host: "example.invalid", port: 5900).qualityIndex == 3, "global quality is never implicitly inherited by a new endpoint")
        expect(store.load(host: "example.invalid", port: 5900, legacyQuality: 2).qualityIndex == 2, "explicit old last-profile quality can be migrated")
        expect(store.load(host: "example.invalid", port: 5900, legacyQuality: nil).zoomMode == .fit, "missing legacy quality still defaults Fit")
        expect(defaults.object(forKey: storageKey) == nil && defaults.integer(forKey: "quality") == 2, "legacy fallback load does not mutate endpoint/global preferences")
        expect(store.save(host: " EXAMPLE.INVALID \n", port: 5900, zoomMode: .scale(1.17), qualityIndex: 1), "save custom/pinch scale")
        expect(store.load(host: "example.invalid", port: 5900) == ConnectionPreferences(zoomMode: .scale(1.17), qualityIndex: 1), "trimmed case-insensitive endpoint restores custom scale")
        expect(store.load(host: "EXAMPLE.INVALID", port: 5900, legacyQuality: 2).qualityIndex == 1, "saved endpoint wins over legacy fallback")
        expect(store.load(host: "example.invalid", port: 5901) == initial, "ports are isolated")
        expect(store.load(host: "other.invalid", port: 5900) == initial, "hosts are isolated")
        expect(store.save(host: "other.invalid", port: 5900, zoomMode: .automatic, qualityIndex: 2), "save Auto and Fast")
        expect(store.save(host: "example.invalid", port: 5901, zoomMode: .fit, qualityIndex: 0), "save Fit and Balanced independently")
        let restarted = ConnectionPreferencesStore(defaults: UserDefaults(suiteName: suite)!)
        expect(restarted.load(host: "example.invalid", port: 5900) == ConnectionPreferences(zoomMode: .scale(1.17), qualityIndex: 1), "new store instance restores persisted scale and quality")
        expect(restarted.load(host: "other.invalid", port: 5900) == ConnectionPreferences(zoomMode: .automatic, qualityIndex: 2), "new instance restores Auto")
        expect(restarted.load(host: "example.invalid", port: 5901) == ConnectionPreferences(zoomMode: .fit, qualityIndex: 0), "new instance restores separate port")

        for (value, expected) in [(0.001, 0.1), (0.1, 0.1), (0.5, 0.5), (4, 4), (10, 4)] {
            expect(store.save(host: "scale.invalid", port: 5900, zoomMode: .scale(value), qualityIndex: 3), "finite zoom saves")
            expect(store.load(host: "scale.invalid", port: 5900).zoomMode == .scale(expected), "finite zoom is bounded")
        }
        let validBefore = defaults.dictionary(forKey: storageKey) as NSDictionary?
        for invalid in [Double.nan, Double.infinity, -Double.infinity] {
            expect(!store.save(host: "scale.invalid", port: 5900, zoomMode: .scale(invalid), qualityIndex: 3), "nonfinite scale rejected")
        }
        expect((defaults.dictionary(forKey: storageKey) as NSDictionary?) == validBefore, "nonfinite save never overwrites stored choices")
        expect(store.save(host: "quality.invalid", port: 5900, zoomMode: .fit, qualityIndex: 999), "high quality index sanitized")
        expect(store.load(host: "quality.invalid", port: 5900).qualityIndex == 3, "high quality index capped")
        expect(store.save(host: "quality.invalid", port: 5900, zoomMode: .fit, qualityIndex: -7), "negative quality sanitized")
        expect(store.load(host: "quality.invalid", port: 5900).qualityIndex == 0, "negative quality bounded")
        expect(store.save(host: "[2001:DB8::1]", port: 5999, zoomMode: .scale(2), qualityIndex: 3), "IPv6 endpoint saves")
        expect(store.load(host: "2001:db8::1", port: 5999) == ConnectionPreferences(zoomMode: .scale(2), qualityIndex: 3), "IPv6 bracket/case aliases restore same endpoint")
        expect(ConnectionPreferencesStore.endpointKey(host: "ÄBC.invalid", port: 5900) == ConnectionPreferencesStore.endpointKey(host: "äbc.invalid", port: 5900), "Unicode case folding")
        expect(ConnectionPreferencesStore.endpointKey(host: "fe80::1%en0", port: 5900) != ConnectionPreferencesStore.endpointKey(host: "fe80::1%en1", port: 5900), "IPv6 scopes remain distinct")
        for address in ["::", "::1", "2001:db8::1", "1:2:3:4:5:6:7:8", "::ffff:192.0.2.1", "fe80::1%en0"] {
            expect(ConnectionPreferencesStore.endpointKey(host: address, port: 5900) != nil, "valid IPv6 accepted without network access")
        }
        let beforeInvalid = defaults.dictionary(forKey: storageKey) as NSDictionary?
        for address in ["", " \n", "host/path", "host name", "host\u{0}name", "vnc://host", "[::1", "::1]", "local:5900", "1:2", ":::1", "2001:zz::1", "::1::", "999.1.1.1", "-bad.invalid", "::ffff:192.0.002.1"] {
            expect(!store.save(host: address, port: 5900, zoomMode: .fit, qualityIndex: 3), "invalid endpoint is not persisted")
            expect(!store.remove(host: address, port: 5900), "invalid endpoint cannot remove another preference")
        }
        expect(!store.save(host: "example.invalid", port: 0, zoomMode: .fit, qualityIndex: 3), "port zero rejected")
        expect((defaults.dictionary(forKey: storageKey) as NSDictionary?) == beforeInvalid, "invalid endpoints never mutate preferences")

        let key = ConnectionPreferencesStore.endpointKey(host: "example.invalid", port: 5900)!
        var entries = defaults.dictionary(forKey: storageKey)!
        let untouched = store.load(host: "other.invalid", port: 5900)
        entries[key] = Data("not JSON".utf8); defaults.set(entries, forKey: storageKey)
        expect(store.load(host: "example.invalid", port: 5900, legacyQuality: 1) == initial, "corrupt entry falls back Fit and new quality")
        expect(store.load(host: "other.invalid", port: 5900) == untouched, "one corrupt entry does not discard another endpoint")
        entries[key] = Data(#"{"kind":"unknown","scale":1.7,"qualityIndex":2}"#.utf8); defaults.set(entries, forKey: storageKey)
        expect(store.load(host: "example.invalid", port: 5900) == ConnectionPreferences(zoomMode: .fit, qualityIndex: 2), "unknown zoom defaults Fit while preserving valid quality")
        entries[key] = Data(#"{"kind":"scale","qualityIndex":99}"#.utf8); defaults.set(entries, forKey: storageKey)
        expect(store.load(host: "example.invalid", port: 5900) == initial, "missing scale falls back Fit and capped quality")
        entries[key] = Data(#"{"kind":"scale","scale":0.001,"qualityIndex":-1}"#.utf8); defaults.set(entries, forKey: storageKey)
        expect(store.load(host: "example.invalid", port: 5900) == ConnectionPreferences(zoomMode: .scale(0.1), qualityIndex: 0), "loaded numeric values sanitized")
        entries[key] = Data(#"{"kind":"fit","qualityIndex":"bad"}"#.utf8); defaults.set(entries, forKey: storageKey)
        expect(store.load(host: "example.invalid", port: 5900) == initial, "malformed quality falls back safely")
        defaults.set("wrong root type", forKey: storageKey)
        expect(store.load(host: "example.invalid", port: 5900, legacyQuality: 1) == initial, "corrupt preference root does not inherit a legacy fallback")
        expect(store.save(host: "example.invalid", port: 5900, zoomMode: .fit, qualityIndex: 3), "explicit save repairs corrupt root")
        let dtoMap = defaults.dictionary(forKey: storageKey)!
        let data = dtoMap[key] as! Data
        let dto = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        expect(Set(dto.keys) == Set(["kind", "qualityIndex"]), "Fit DTO contains display fields only")
        expect(!String(data: data, encoding: .utf8)!.lowercased().contains("password"), "preference DTO has no credential fields")
        expect(defaults.integer(forKey: "quality") == 2, "per-endpoint writes leave old global setting untouched")
        expect(store.remove(host: "example.invalid", port: 5900), "remove saved endpoint")
        expect(store.load(host: "example.invalid", port: 5900) == initial && defaults.object(forKey: storageKey) == nil, "last removal restores default without stale data")
        expect(store.remove(host: "example.invalid", port: 5900), "missing deletion idempotent")
        print("PASS: \(checks) per-endpoint connection preference defaults, persistence, migration fallback, bounds, corruption, isolation, and credential-free DTO checks")
    }
}
