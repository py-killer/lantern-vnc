// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

@main
struct DeviceStoreTests {
    static func main() throws {
        let suite = "local.lantern.vnc.device-store-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = DeviceStore(defaults: defaults)
        assert(store.devices.count == 1)
        assert(store.devices[0].host == "192.168.0.101" && store.devices[0].port == 5900)
        assert(store.devices[0].name == "TightVNC server")
        let originalID = store.devices[0].id
        assert(store.save(name: " Office PC ", host: " 192.168.0.101 ", port: 5900)?.id == originalID)
        assert(store.devices[0].name == "Office PC")
        let second = store.save(name: "Workstation", host: "Workstation.LOCAL", port: 5901)!
        let third = store.save(name: "", host: "192.168.0.103", port: 5900)!
        assert(third.name == third.host)
        assert(store.devices.count == 3)
        assert(store.save(name: "Fourth", host: "192.168.0.104", port: 5900) == nil)
        assert(store.save(name: "Renamed", host: "workstation.local", port: 5901)?.id == second.id)
        assert(store.devices.count == 3)
        assert(store.find(host: " WORKSTATION.LOCAL ", port: 5901)?.name == "Renamed")
        assert(store.find(host: "workstation.local", port: 5900) == nil)
        assert(store.save(name: "Invalid", host: "  ", port: 5900) == nil)
        assert(store.save(name: "Invalid", host: "host/path", port: 5900) == nil)
        assert(store.save(name: "Invalid", host: "host name", port: 5900) == nil)
        assert(store.save(name: "Invalid", host: "valid.local", port: 0) == nil)

        let reloaded = DeviceStore(defaults: defaults)
        assert(reloaded.devices == store.devices)
        let encoded = defaults.data(forKey: "savedDevices.v1")!
        let dictionaries = try JSONSerialization.jsonObject(with: encoded) as! [[String: Any]]
        assert(dictionaries.count == 3)
        assert(dictionaries.allSatisfy { Set($0.keys) == Set(["id", "name", "host", "port"]) })
        assert(!String(data: encoded, encoding: .utf8)!.lowercased().contains("password"))

        store.remove(id: originalID)
        assert(store.devices.count == 2)
        assert(store.save(name: "Fourth", host: "192.168.0.104", port: 5900) != nil)
        for device in store.devices { store.remove(id: device.id) }
        assert(DeviceStore(defaults: defaults).devices.isEmpty, "Deleted profiles must not reappear")

        defaults.removePersistentDomain(forName: suite)
        defaults.set(" current.local ", forKey: "server")
        defaults.set("5905", forKey: "port")
        let migrated = DeviceStore(defaults: defaults)
        assert(migrated.devices.count == 1 && migrated.devices[0].host == "current.local")
        assert(migrated.devices[0].port == 5905)

        let duplicates = [SavedDevice(id: "a", name: "First", host: "same.local", port: 5900),
                          SavedDevice(id: "b", name: "Duplicate", host: "SAME.LOCAL", port: 5900),
                          SavedDevice(id: "c", name: "Invalid", host: "", port: 5900),
                          SavedDevice(id: "d", name: "Two", host: "two.local", port: 5900),
                          SavedDevice(id: "e", name: "Three", host: "three.local", port: 5900),
                          SavedDevice(id: "f", name: "Four", host: "four.local", port: 5900)]
        defaults.set(try JSONEncoder().encode(duplicates), forKey: "savedDevices.v1")
        let sanitized = DeviceStore(defaults: defaults)
        assert(sanitized.devices.map(\.id) == ["a", "d", "e"])

        print("PASS: saved devices default/migration, capacity, rename, case-insensitive deduplication, persistence, deletion, sanitization, and credential-free schema")
    }
}
