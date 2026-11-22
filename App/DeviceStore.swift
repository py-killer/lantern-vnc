// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Saved connection details deliberately exclude credentials.
struct SavedDevice: Codable, Equatable {
    let id: String
    var name: String
    var host: String
    var port: UInt16
}

/// The workspace keeps one interactive VNC screen and remembers up to three destinations.
final class DeviceStore {
    static let maximumDevices = 3
    private static let storageKey = "savedDevices.v1"
    private let defaults: UserDefaults
    private(set) var devices: [SavedDevice] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored = defaults.object(forKey: Self.storageKey) {
            if let data = stored as? Data,
               let decoded = try? JSONDecoder().decode([SavedDevice].self, from: data) {
                for device in decoded {
                    guard devices.count < Self.maximumDevices,
                          let address = Self.cleanHost(device.host), device.port > 0,
                          !devices.contains(where: { $0.id == device.id }),
                          find(host: address, port: device.port) == nil else { continue }
                    devices.append(SavedDevice(id: device.id.isEmpty ? UUID().uuidString : device.id,
                                               name: Self.cleanName(device.name, host: address),
                                               host: address, port: device.port))
                }
            }
        } else {
            let address = Self.cleanHost(defaults.string(forKey: "server") ?? "") ?? "192.168.0.101"
            let configuredPort = defaults.string(forKey: "port").flatMap(UInt16.init) ?? 5900
            devices = [SavedDevice(id: UUID().uuidString, name: "TightVNC server",
                                   host: address, port: configuredPort > 0 ? configuredPort : 5900)]
        }
        persist()
    }

    func find(host: String, port: UInt16) -> SavedDevice? {
        guard let address = Self.cleanHost(host) else { return nil }
        return devices.first { $0.host.caseInsensitiveCompare(address) == .orderedSame && $0.port == port }
    }

    /// Updates an existing destination, including at capacity. Returns nil for
    /// invalid details or a fourth distinct destination.
    @discardableResult
    func save(name: String, host: String, port: UInt16) -> SavedDevice? {
        guard let address = Self.cleanHost(host), port > 0 else { return nil }
        if let existing = find(host: address, port: port),
           let index = devices.firstIndex(where: { $0.id == existing.id }) {
            let updated = SavedDevice(id: existing.id, name: Self.cleanName(name, host: address),
                                      host: address, port: port)
            devices[index] = updated
            persist()
            return updated
        }
        guard devices.count < Self.maximumDevices else { return nil }
        let device = SavedDevice(id: UUID().uuidString, name: Self.cleanName(name, host: address),
                                 host: address, port: port)
        devices.append(device)
        persist()
        return device
    }

    func remove(id: String) {
        devices.removeAll { $0.id == id }
        persist()
    }

    private static func cleanHost(_ value: String) -> String? {
        let address = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, !address.contains("/"),
              address.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        return address
    }

    private static func cleanName(_ value: String, host: String) -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? host : name
    }

    private func persist() {
        if let encoded = try? JSONEncoder().encode(devices) {
            defaults.set(encoded, forKey: Self.storageKey)
        }
    }
}
