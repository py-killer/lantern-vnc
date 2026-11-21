// SPDX-License-Identifier: GPL-2.0-or-later
// Real ViewerController + owned loopback VNC fixtures + fake credential storage.
// No user Keychain access, global input, app activation, or LAN discovery.
import AppKit
import MetalKit
import Foundation

private final class ConnectionPasswordStore: PasswordStorage {
    struct Save { let host: String; let port: UInt16; let password: String }
    var values: [String: String] = [:]
    var saves: [Save] = []
    var removes: [(String, UInt16)] = []
    var failRead = false, failSave = false, failRemove = false
    private func key(_ host: String, _ port: UInt16) throws -> String {
        try PasswordStore.account(host: host, port: port)
    }
    func seed(host: String, port: UInt16, value: String) throws { values[try key(host, port)] = value }
    func value(host: String, port: UInt16) throws -> String? { values[try key(host, port)] }
    func read(host: String, port: UInt16) throws -> String? {
        if failRead { throw PasswordStoreError.keychain(errSecAuthFailed) }
        return try value(host: host, port: port)
    }
    func save(host: String, port: UInt16, password: String) throws {
        if failSave { throw PasswordStoreError.keychain(errSecAuthFailed) }
        values[try key(host, port)] = password
        saves.append(Save(host: host, port: port, password: password))
    }
    func remove(host: String, port: UInt16) throws {
        if failRemove { throw PasswordStoreError.keychain(errSecAuthFailed) }
        values.removeValue(forKey: try key(host, port)); removes.append((host, port))
    }
}

@main
struct ConnectionSettingsHarness {
    private static var checks = 0
    private static func expect(_ value: Bool, _ label: String) {
        checks += 1
        guard value else { fatalError("Connection settings harness: \(label)") }
    }
    private static func settle(_ seconds: TimeInterval = 0.02) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
    }
    private static func wait(_ label: String, timeout: TimeInterval = 8, until ready: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !ready() && Date() < deadline { settle() }
        expect(ready(), label)
    }
    private static func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }
    private static func find<T: NSView>(_ id: String, in content: NSView, as: T.Type) -> T {
        guard let value = allViews(content).first(where: { $0.identifier?.rawValue == id }) as? T else {
            fatalError("Connection settings harness: missing owned control \(id)")
        }
        return value
    }
    private static func toggle(_ button: NSButton, to value: NSControl.StateValue) {
        button.state = value
        expect(button.sendAction(button.action, to: button.target), "remember checkbox action is connected")
    }
    private static func change(_ field: NSTextField, to value: String, controller: ViewerController) {
        field.stringValue = value
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    }
    private static func finish(_ field: NSTextField, controller: ViewerController) {
        controller.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
    }
    private static func closeOwnedSheet(_ parent: NSWindow) {
        if let sheet = parent.attachedSheet { parent.endSheet(sheet); sheet.orderOut(nil); settle() }
        expect(parent.attachedSheet == nil, "owned error sheet can be dismissed without global input")
    }

    static func main() throws {
        guard CommandLine.arguments.count == 5,
              let passwordPort = UInt16(CommandLine.arguments[1]),
              let failurePort = UInt16(CommandLine.arguments[2]),
              let stalledPort = UInt16(CommandLine.arguments[3]) else {
            fputs("Usage: connection-settings-harness password-port failure-port stalled-port report.json\n", stderr)
            exit(2)
        }
        guard MTLCreateSystemDefaultDevice() != nil, !NSScreen.screens.isEmpty else {
            fputs("UNAVAILABLE: owned native settings checks need Metal/WindowServer access (exit 77).\n", stderr)
            exit(77)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let suite = "LanternVNC.ConnectionSettings.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        preferences.removePersistentDomain(forName: suite)
        preferences.set("127.0.0.1", forKey: "server")
        preferences.set(String(passwordPort), forKey: "port")
        preferences.set(false, forKey: "clipboard")
        let productionBefore = UserDefaults.standard.persistentDomain(forName: "local.lantern.vnc")
        let store = ConnectionPasswordStore()
        let controller = try ViewerController(showWindow: false, preferences: preferences, passwordStore: store)
        guard let window = controller.window, let content = window.contentView else { fatalError("Missing test window") }
        defer {
            controller.stop()
            if let sheet = window.attachedSheet { window.endSheet(sheet); sheet.orderOut(nil) }
            window.delegate = nil; window.orderOut(nil); window.close()
            preferences.removePersistentDomain(forName: suite)
        }
        window.ignoresMouseEvents = true
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000)); window.orderBack(nil)
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000)); content.layoutSubtreeIfNeeded(); settle()
        let host: NSTextField = find("serverHost", in: content, as: NSTextField.self)
        let port: NSTextField = find("serverPort", in: content, as: NSTextField.self)
        let password: NSSecureTextField = find("serverPassword", in: content, as: NSSecureTextField.self)
        let remember: NSButton = find("rememberPassword", in: content, as: NSButton.self)
        let connect: NSButton = find("connectButton", in: content, as: NSButton.self)
        func endpoint(_ address: String, _ number: UInt16) {
            change(host, to: address, controller: controller)
            change(port, to: String(number), controller: controller)
            finish(port, controller: controller)
        }
        func connected() { wait("owned password server authenticates and controller connects") { connect.title == "Disconnect" && connect.isEnabled } }
        func disconnect() {
            controller.toggleConnection()
            wait("owned session stops and settings become available") { connect.title == "Connect" && connect.isEnabled }
        }

        expect(!window.isKeyWindow, "offscreen test window never takes keyboard focus")
        expect(remember.state == .off && password.stringValue.isEmpty, "new endpoint defaults to remember OFF and empty password")
        password.stringValue = "mock-password"
        controller.toggleConnection()
        expect(password.stringValue.isEmpty, "password field cleared on connection start")
        connected()
        expect(store.saves.isEmpty, "successful authentication does not save when remember is OFF")
        disconnect()
        expect(remember.state == .off && password.stringValue.isEmpty, "unsaved endpoint stays empty after disconnect")

        password.stringValue = "mock-password"
        toggle(remember, to: .on)
        expect(store.saves.isEmpty, "toggling ON does not save before authentication")
        controller.toggleConnection()
        expect(store.saves.isEmpty, "starting an attempt does not save before onConnected")
        expect(!host.isEnabled && !port.isEnabled && !remember.isEnabled, "connection endpoint and remember choice frozen during attempt")
        connected()
        expect(store.saves.count == 1, "successful remembered authentication saves exactly once")
        expect(store.saves[0].host == "127.0.0.1" && store.saves[0].port == passwordPort, "only selected loopback endpoint saved")
        expect(store.saves[0].password == "mock-password", "entered password reaches fake credential storage intact")
        disconnect()
        expect(remember.state == .on && password.stringValue == "mock-password", "stored password loaded and checkbox ON after disconnect")
        toggle(remember, to: .off)
        expect(try store.value(host: "127.0.0.1", port: passwordPort) == nil, "unchecking removes selected stored credential")

        try store.seed(host: "second.invalid", port: passwordPort, value: "second-fixture-value")
        try store.seed(host: "second.invalid", port: failurePort, value: "port-fixture-value")
        password.stringValue = "prior-fixture-value"
        change(host, to: "second.invalid", controller: controller)
        expect(password.stringValue.isEmpty && remember.state == .off, "host edit immediately clears previous password and checkbox")
        finish(host, controller: controller)
        expect(password.stringValue == "second-fixture-value" && remember.state == .on, "host edit completion loads only new endpoint credential")
        change(port, to: String(failurePort), controller: controller)
        expect(password.stringValue.isEmpty && remember.state == .off, "port edit immediately clears previous password")
        finish(port, controller: controller)
        expect(password.stringValue == "port-fixture-value" && remember.state == .on, "port edit completion loads only matching port")
        change(port, to: "", controller: controller); finish(port, controller: controller)
        expect(password.stringValue.isEmpty && remember.state == .off, "incomplete endpoint never retains prior password")

        try store.seed(host: "127.0.0.1", port: failurePort, value: "prior-accepted-fixture")
        endpoint("127.0.0.1", failurePort)
        expect(password.stringValue == "prior-accepted-fixture" && remember.state == .on, "failure fixture starts with existing saved credential")
        password.stringValue = "wrong-fixture-value"
        controller.toggleConnection()
        wait("auth rejection restores settings") { connect.title == "Connect" && connect.isEnabled }
        expect(store.saves.count == 1, "authentication failure never saves or overwrites")
        expect(try store.value(host: "127.0.0.1", port: failurePort) == "prior-accepted-fixture", "previous saved value survives failed authentication")
        expect(password.stringValue == "prior-accepted-fixture" && remember.state == .on, "saved credential reloads after rejection")

        endpoint("127.0.0.1", stalledPort)
        password.stringValue = "canceled-fixture-value"; toggle(remember, to: .on)
        controller.toggleConnection(); settle(0.12)
        expect(connect.title == "Cancel" && store.saves.count == 1, "stalled unauthenticated session never saves")
        disconnect()
        expect(try store.value(host: "127.0.0.1", port: stalledPort) == nil, "canceled attempt leaves no stored credential")

        endpoint("127.0.0.1", passwordPort)
        password.stringValue = "mock-password"; toggle(remember, to: .on); store.failSave = true
        controller.toggleConnection(); connected()
        expect(remember.state == .off && store.saves.count == 1, "save failure clears remember without dropping successful connection")
        expect(window.attachedSheet != nil, "save failure presents an owned error sheet")
        closeOwnedSheet(window); store.failSave = false; disconnect()
        expect(try store.value(host: "127.0.0.1", port: passwordPort) == nil, "failed storage operation does not invent a saved value")

        try store.seed(host: "127.0.0.1", port: passwordPort, value: "retained-fixture-value")
        endpoint("other.invalid", passwordPort); endpoint("127.0.0.1", passwordPort)
        expect(remember.state == .on && password.stringValue == "retained-fixture-value", "known credential loads before removal test")
        store.failRemove = true; toggle(remember, to: .off)
        expect(remember.state == .on, "failed removal restores checked indicator")
        expect(try store.value(host: "127.0.0.1", port: passwordPort) == "retained-fixture-value", "failed removal preserves existing value")
        closeOwnedSheet(window); store.failRemove = false; toggle(remember, to: .off)
        expect(try store.value(host: "127.0.0.1", port: passwordPort) == nil, "removal can be retried successfully")

        store.failRead = true; endpoint("read-error.invalid", passwordPort)
        expect(password.stringValue.isEmpty && remember.state == .off, "read failure remains empty and opt-in OFF")
        expect(window.attachedSheet == nil, "read failure does not block entry with a modal alert")
        store.failRead = false
        func profiles() throws -> [SavedDevice] {
            guard let encoded = preferences.data(forKey: "savedDevices.v1") else {
                fatalError("Connection settings harness: missing owned profile data")
            }
            return try JSONDecoder().decode([SavedDevice].self, from: encoded)
        }
        let beforeConfirmation = try profiles()
        expect(beforeConfirmation.count == 1, "loopback authentication scenarios retain one saved endpoint")
        let discovered = DiscoveredVNCServer(host: "found-one.invalid", port: 5999, protocolVersion: "003.008")
        let another = DiscoveredVNCServer(host: "found-two.invalid", port: 6000, protocolVersion: "003.008")
        controller.acceptDiscoveredServer(discovered, alias: "Office fixture")
        let immediatelySaved = try profiles()
        let selectedProfile = immediatelySaved.first(where: { $0.host == discovered.host && $0.port == discovered.port })
        expect(immediatelySaved.count == 2 && selectedProfile?.name == "Office fixture", "confirming discovery persists alias/host/port before authentication")
        expect(host.stringValue == discovered.host && port.stringValue == "5999", "confirmation selects the discovered endpoint in connection fields")
        expect(connect.title == "Connect" && connect.isEnabled && store.saves.count == 1, "profile confirmation neither authenticates nor stores a password")
        expect(password.stringValue.isEmpty && remember.state == .off, "newly confirmed computer does not inherit a prior password")
        let picker: NSPopUpButton = find("savedDevicePicker", in: content, as: NSPopUpButton.self)
        expect(picker.selectedItem?.title.hasPrefix("Office fixture · ") == true &&
               picker.selectedItem?.representedObject as? String == selectedProfile?.id,
               "confirmed alias appears selected in the actual saved-device picker")
        controller.acceptDiscoveredServer(discovered, alias: nil)
        expect(try profiles().first(where: { $0.id == selectedProfile?.id })?.name == "Office fixture", "confirming an existing endpoint keeps its known alias")
        controller.acceptDiscoveredServer(discovered, alias: "Renamed office fixture")
        expect(try profiles().count == 2 && profiles().first(where: { $0.id == selectedProfile?.id })?.name == "Renamed office fixture", "editing the discovered alias updates the same saved profile")
        controller.acceptDiscoveredServer(another, alias: "Lab fixture")
        expect(try profiles().count == 3, "third confirmed computer persists immediately")
        let atCapacity = try profiles()
        let overflow = DiscoveredVNCServer(host: "overflow.invalid", port: 6001, protocolVersion: "003.008")
        controller.acceptDiscoveredServer(overflow, alias: "Overflow fixture")
        expect(try profiles() == atCapacity, "full list never creates an unconfirmed fourth saved profile")
        expect(host.stringValue == overflow.host && port.stringValue == "6001", "capacity fallback retains only a manual one-off endpoint")
        expect(window.attachedSheet != nil, "capacity fallback honestly explains that the computer was not added")
        closeOwnedSheet(window)
        expect(store.saves.count == 1 && connect.title == "Connect", "all discovered-profile confirmations leave password saving authentication-only")
        let domain = preferences.persistentDomain(forName: suite) ?? [:]
        let data = try PropertyListSerialization.data(fromPropertyList: domain, format: .binary, options: 0)
        for value in ["mock-password", "second-fixture-value", "port-fixture-value", "prior-fixture-value",
                      "prior-accepted-fixture", "wrong-fixture-value", "canceled-fixture-value", "retained-fixture-value"] {
            expect(data.range(of: Data(value.utf8)) == nil, "no synthetic password bytes persisted in temporary defaults")
        }
        expect(NSDictionary(dictionary: productionBefore ?? [:]).isEqual(to: UserDefaults.standard.persistentDomain(forName: "local.lantern.vnc") ?? [:]), "production app preferences unchanged")
        expect(!window.isKeyWindow, "settings actions never activate the offscreen test window")
        let report: [String: Any] = ["checks": checks, "keychainAccess": "none; injected in-memory fake",
            "networkScope": "owned 127.0.0.1 mock servers only", "globalInputEvents": 0,
            "windowPresentation": "owned offscreen non-key", "successfulPasswordSaves": store.saves.count,
            "confirmedProfilesSavedBeforeAuthentication": 2,
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: CommandLine.arguments[4]))
        print("PASS: \(checks) real-controller password settings/authentication/isolation checks")
    }
}
