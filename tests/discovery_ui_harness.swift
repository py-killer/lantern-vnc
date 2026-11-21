// SPDX-License-Identifier: GPL-2.0-or-later
// Uses an injected fake scanner and synthetic LAN plans in owned offscreen
// windows. No real network interfaces, connections, passwords, or global input.
import AppKit
import Foundation

private final class FakeDiscovery: VNCDiscovering {
    struct Request { let network: LANNetwork; let port: UInt16 }
    private(set) var requests: [Request] = []
    private(set) var cancellations = 0
    var throwOnNextScan = false
    private var update: ((VNCDiscoveryProgress) -> Void)?
    private var complete: (([DiscoveredVNCServer]) -> Void)?

    func scan(network: LANNetwork, port: UInt16,
              onUpdate: @escaping (VNCDiscoveryProgress) -> Void,
              onComplete: @escaping ([DiscoveredVNCServer]) -> Void) throws {
        requests.append(Request(network: network, port: port))
        if throwOnNextScan {
            throwOnNextScan = false
            throw VNCDiscoveryError.invalidPort
        }
        update = onUpdate; complete = onComplete
    }
    func cancel() {
        cancellations += 1
        update = nil; complete = nil
    }
    @discardableResult func publish(_ servers: [DiscoveredVNCServer], completed: Int, total: Int) -> Bool {
        guard let update = update else { return false }
        update(VNCDiscoveryProgress(servers: servers, completed: completed, total: total))
        return true
    }
    @discardableResult func finish(_ servers: [DiscoveredVNCServer]) -> Bool {
        guard let callback = complete else { return false }
        update = nil; complete = nil
        callback(servers)
        return true
    }
}

private enum HarnessError: Error { case missingControl(String), missingWindow }

private final class Fixture {
    let scanner = FakeDiscovery()
    let controller: VNCDiscoveryController
    let window: NSWindow
    let content: NSView

    init(networks: @escaping () throws -> [LANNetwork],
         knownAlias: @escaping (String, UInt16) -> String? = { _, _ in nil }) throws {
        controller = VNCDiscoveryController(scanner: scanner, networksProvider: networks, knownAlias: knownAlias)
        guard let ownedWindow = controller.window, let ownedContent = ownedWindow.contentView else {
            throw HarnessError.missingWindow
        }
        window = ownedWindow; content = ownedContent
        window.ignoresMouseEvents = true
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderBack(nil)
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        content.layoutSubtreeIfNeeded()
    }
    deinit {
        controller.onClose = nil
        controller.dismiss()
        window.orderOut(nil)
        window.close()
    }
    func control<T: NSView>(_ id: String, as type: T.Type) throws -> T {
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        guard let result = descendants(content).first(where: { $0.identifier?.rawValue == id }) as? T else {
            throw HarnessError.missingControl(id)
        }
        return result
    }
    var status: String { (try? control("discoveryStatus", as: NSTextField.self).stringValue) ?? "" }
    func search() throws { try control("discoverySearch", as: NSButton.self).performClick(nil) }
    func select(row: Int) throws {
        let table = try control("discoveryResults", as: NSTableView.self)
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
    }
}

@main
struct DiscoveryUIHarness {
    private static var checks = 0
    private static var failures: [String] = []
    private static var scenarios: [String] = []
    private static var observations: [String: String] = [:]
    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) {
        checks += 1
        do {
            let passed = try condition()
            if !passed { failures.append(message); fputs("FAIL: \(message)\n", stderr) }
        } catch {
            failures.append("\(message): \(error)")
            fputs("FAIL: \(message): \(error)\n", stderr)
        }
    }

    private static func run() throws {
        let first = try LANNetwork(interfaceName: "en0", address: "192.168.50.10", netmask: "255.255.255.0")
        let second = try LANNetwork(interfaceName: "en5", address: "10.20.30.10", netmask: "255.255.0.0")
        let high = DiscoveredVNCServer(host: "192.168.50.120", port: 5999, protocolVersion: "003.008")
        let low = DiscoveredVNCServer(host: "192.168.50.12", port: 5999, protocolVersion: "003.003")

        do {
            let fixture = try Fixture(networks: { [] })
            var selections = 0
            fixture.controller.configure(port: 5900) { _ in selections += 1 }
            expect(fixture.scanner.requests.isEmpty, "configure with no interfaces never scans")
            expect(fixture.scanner.cancellations == 1, "configure invalidates an earlier scanner generation")
            expect(!(try fixture.control("discoverySearch", as: NSButton.self)).isEnabled, "search disabled with no network")
            expect(!(try fixture.control("discoveryNetwork", as: NSPopUpButton.self)).isEnabled, "network picker disabled with no network")
            expect(!(try fixture.control("discoveryUseServer", as: NSButton.self)).isEnabled, "Use Server disabled without a result")
            expect(fixture.status.contains("No supported local IPv4 network"), "no-interface status gives manual-address guidance")
            try fixture.search()
            expect(fixture.scanner.requests.isEmpty && selections == 0, "disabled search cannot start traffic or select a server")
            expect(!fixture.window.isKeyWindow && !fixture.window.isMainWindow, "owned discovery window takes no keyboard focus")
            scenarios.append("no interfaces")
        }

        do {
            var providerCalls = 0
            let fixture = try Fixture(networks: { providerCalls += 1; throw VNCDiscoveryError.interfacesUnavailable })
            fixture.controller.configure(port: 5901) { _ in failures.append("unexpected selection after provider error") }
            expect(providerCalls == 1, "configure uses only the injected network provider")
            expect(fixture.scanner.requests.isEmpty, "throwing provider never starts scanner")
            expect(!(try fixture.control("discoverySearch", as: NSButton.self)).isEnabled, "provider error disables search")
            expect(fixture.status.contains("Couldn’t read the local network"), "provider error appears in owned status label")
            scenarios.append("network provider error")
        }

        do {
            let fixture = try Fixture(networks: { [first, second] })
            var selected: [DiscoveredVNCServer] = []
            var selectedAlias: String?
            var closed = 0
            fixture.controller.onClose = { closed += 1 }
            fixture.controller.configure(port: 5999) { server, alias in
                selected.append(server)
                selectedAlias = alias
            }
            let picker = try fixture.control("discoveryNetwork", as: NSPopUpButton.self)
            let table = try fixture.control("discoveryResults", as: NSTableView.self)
            let use = try fixture.control("discoveryUseServer", as: NSButton.self)
            let alias = try fixture.control("discoveryAlias", as: NSTextField.self)
            expect(fixture.scanner.requests.isEmpty, "configure on valid networks does not begin scanning")
            expect(alias.stringValue.isEmpty && fixture.controller.chosenAlias == nil, "no alias is chosen before a server is selected")
            expect(!alias.isEnabled, "name field is disabled before selection")
            expect(use.title == "Save Computer", "picker action clearly saves a computer")
            expect(picker.numberOfItems == 2 && picker.itemTitles == [first.displayName, second.displayName], "synthetic network options are populated exactly")
            expect((try fixture.control("discoverySearch", as: NSButton.self)).isEnabled, "search enabled for a valid injected network")
            expect(fixture.status == "Ready to search your local network.", "configured controller starts ready")

            picker.selectItem(at: 1)
            expect(picker.sendAction(picker.action, to: picker.target), "network picker is connected to its local action")
            expect(fixture.scanner.requests.isEmpty, "network selection alone does not scan")
            try fixture.search()
            expect(fixture.scanner.requests.count == 1, "Search invokes fake scanner once")
            expect(fixture.scanner.requests.last?.network == second && fixture.scanner.requests.last?.port == 5999, "search forwards selected network and exact TCP port")
            expect(fixture.status == "Looking for VNC servers…", "running scan status appears")
            expect(fixture.scanner.publish([high], completed: 7, total: 255), "fake can deliver main-thread progress")
            expect(table.numberOfRows == 1 && fixture.status == "1 found · 7 of 255 addresses checked", "progress updates real table and status")
            expect(!use.isEnabled, "a result is not silently selected")
            try fixture.select(row: 0)
            expect(use.isEnabled && alias.isEnabled && alias.isEditable, "explicit table selection enables Save Computer and its name field")
            expect(alias.stringValue == "VNC computer", "an unnamed selected computer gets a useful default name")
            alias.stringValue = "   \n\t  "
            expect(fixture.controller.chosenAlias == nil, "whitespace-only name is omitted")
            alias.stringValue = "  Office\nPC\tDesk  "
            expect(fixture.controller.chosenAlias == "Office PC Desk", "name trims surrounding whitespace and replaces control characters")
            alias.stringValue = String(repeating: "机", count: 85)
            expect(fixture.controller.chosenAlias == String(repeating: "机", count: 80), "name is limited to eighty Unicode characters")
            alias.stringValue = "  Office PC  "
            expect(fixture.controller.chosenAlias == "Office PC", "editing a selected computer name exposes the trimmed value")
            expect(fixture.scanner.publish([low, high], completed: 18, total: 255), "fake can publish a reordered result set")
            expect(table.selectedRow == 1, "progress preserves the selected host when row order changes")
            expect(fixture.controller.chosenAlias == "Office PC", "reordered progress preserves the selected computer's edited name")
            let hostCell = fixture.controller.tableView(table, viewFor: table.tableColumns[0], row: 1) as? NSTextField
            let portCell = fixture.controller.tableView(table, viewFor: table.tableColumns[1], row: 1) as? NSTextField
            expect(hostCell?.stringValue == high.host && portCell?.stringValue == "5999", "table exposes exact host and port values")
            observations["multiBeforeCompleteAlias"] = fixture.controller.chosenAlias ?? "<nil>"
            observations["multiBeforeCompleteRow"] = String(table.selectedRow)
            expect(fixture.scanner.finish([low, high]), "fake can complete with found servers")
            observations["multiAfterCompleteAlias"] = fixture.controller.chosenAlias ?? "<nil>"
            observations["multiAfterCompleteRow"] = String(table.selectedRow)
            expect(table.numberOfRows == 2 && fixture.status.contains("2 VNC servers found"), "completion leaves selectable found results")
            expect(fixture.controller.chosenAlias == "Office PC", "multi-result completion preserves the selected computer's edited name")
            try fixture.select(row: 1)
            let beforeCancel = fixture.scanner.cancellations
            use.performClick(nil)
            observations["multiCallbackAlias"] = selectedAlias ?? "<nil>"
            expect(selected == [high], "Save Computer returns exactly the selected host, port, and protocol version")
            expect(selectedAlias == "Office PC", "Save Computer callback receives the trimmed alias by value")
            expect(fixture.scanner.cancellations == beforeCancel + 1 && closed == 1, "choosing a result cancels outstanding scan and closes once")
            expect(!fixture.window.isVisible, "choosing a server hides the owned discovery window")
            expect(!fixture.scanner.finish([low]) && selected == [high], "canceled fake cannot deliver another selection")
            scenarios.append("configure, progress, selection/name preservation, found results, Save Computer")
        }

        do {
            let fixture = try Fixture(networks: { [first] })
            var selected: [DiscoveredVNCServer] = []
            var selectedAlias: String?
            var closed = 0
            fixture.controller.onClose = { closed += 1 }
            fixture.controller.configure(port: 5999) { server, alias in selected.append(server); selectedAlias = alias }
            let table = try fixture.control("discoveryResults", as: NSTableView.self)
            let alias = try fixture.control("discoveryAlias", as: NSTextField.self)
            let save = try fixture.control("discoveryUseServer", as: NSButton.self)
            try fixture.search()
            fixture.scanner.publish([high], completed: 1, total: 253)
            expect(table.selectedRow == -1 && !alias.isEnabled, "single progress result waits for completion before automatic selection")
            fixture.scanner.finish([high])
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
            expect(table.selectedRow == 0 && save.isEnabled && alias.isEnabled, "exactly one completed result is selected and ready to name")
            expect(alias.stringValue == "VNC computer", "single unnamed result gets VNC computer as its default")
            let focused = fixture.window.firstResponder === alias || alias.currentEditor().map { fixture.window.firstResponder === $0 } == true
            expect(focused, "single completed result focuses the owned name field")
            expect(selected.isEmpty && closed == 0, "automatic selection never saves or dismisses without confirmation")
            alias.stringValue = "   \n\t "
            let cancellations = fixture.scanner.cancellations
            save.performClick(nil)
            expect(selected.isEmpty && closed == 0 && fixture.window.isVisible, "blank name blocks Save Computer and leaves the picker open")
            expect(fixture.status.contains("Enter a name for this computer"), "blank name gives actionable validation guidance")
            expect(fixture.scanner.cancellations == cancellations, "blank-name validation does not dismiss or cancel the picker")
            alias.stringValue = "  Quick check PC  "
            save.performClick(nil)
            expect(selected == [high] && selectedAlias == "Quick check PC" && closed == 1, "confirmed name is trimmed and saved only after explicit confirmation")
            scenarios.append("single-result auto-selection, default name, focus, blank guard, confirmation")
        }

        do {
            var aliasLookups: [(String, UInt16)] = []
            let fixture = try Fixture(networks: { [first] }, knownAlias: { host, port in
                aliasLookups.append((host, port))
                return host == high.host && port == high.port ? "Saved office PC" : nil
            })
            var selectedAlias: String?
            fixture.controller.configure(port: 5999) { _, alias in selectedAlias = alias }
            try fixture.search()
            fixture.scanner.finish([high])
            let alias = try fixture.control("discoveryAlias", as: NSTextField.self)
            let table = try fixture.control("discoveryResults", as: NSTableView.self)
            expect(alias.stringValue == "Saved office PC", "a known computer prefills its saved alias")
            expect(aliasLookups.contains(where: { $0.0 == high.host && $0.1 == high.port }), "saved alias lookup uses the exact selected host and TCP port")
            let hostCell = fixture.controller.tableView(table, viewFor: table.tableColumns[0], row: 0) as? NSTextField
            expect(hostCell?.stringValue == "Saved office PC · \(high.host)", "known alias and server address remain visible together")
            try fixture.control("discoveryUseServer", as: NSButton.self).performClick(nil)
            expect(selectedAlias == "Saved office PC", "confirming a known computer returns its prefilled alias")
            scenarios.append("single-result saved alias prefill and confirmation")
        }

        do {
            let fixture = try Fixture(networks: { [first, second] })
            var selections = 0
            let alias = try fixture.control("discoveryAlias", as: NSTextField.self)
            alias.stringValue = "Previous computer"
            fixture.controller.configure(port: 5902) { _ in selections += 1 }
            expect(alias.stringValue.isEmpty && fixture.controller.chosenAlias == nil, "configure clears an alias from an earlier presentation")
            try fixture.search()
            fixture.scanner.publish([high], completed: 1, total: 253)
            try fixture.select(row: 0)
            let picker = try fixture.control("discoveryNetwork", as: NSPopUpButton.self)
            picker.selectItem(at: 1)
            let beforeCancel = fixture.scanner.cancellations
            expect(picker.sendAction(picker.action, to: picker.target), "network change action is delivered")
            expect(fixture.scanner.cancellations == beforeCancel + 1, "changing network cancels old scan")
            expect((try fixture.control("discoveryResults", as: NSTableView.self)).numberOfRows == 0, "network change clears old results")
            expect(!(try fixture.control("discoveryUseServer", as: NSButton.self)).isEnabled, "network change clears selectable result")
            expect(!alias.isEnabled && alias.stringValue.isEmpty, "network change disables and clears the old computer name")
            expect(fixture.scanner.requests.count == 1 && selections == 0, "network change neither scans automatically nor selects")
            try fixture.search()
            fixture.scanner.finish([])
            expect(fixture.status.contains("No VNC servers found"), "empty completion gives useful no-results status")
            expect(!(try fixture.control("discoveryUseServer", as: NSButton.self)).isEnabled, "empty completion has no selectable result")
            expect((try fixture.control("discoverySearch", as: NSButton.self)).isEnabled, "empty result remains retryable")
            scenarios.append("network change and empty completion")
        }

        do {
            let fixture = try Fixture(networks: { [first] })
            var selections = 0
            fixture.controller.configure(port: 5900) { _ in selections += 1 }
            fixture.scanner.throwOnNextScan = true
            try fixture.search()
            expect(fixture.scanner.requests.count == 1, "throwing scanner is invoked once")
            expect(fixture.status.contains("Couldn’t start the search"), "scanner error appears as useful owned UI status")
            expect(!(try fixture.control("discoveryUseServer", as: NSButton.self)).isEnabled && selections == 0, "scanner error does not select a server")
            try fixture.search()
            expect(fixture.scanner.requests.count == 2 && fixture.status == "Looking for VNC servers…", "search can retry after scanner error")
            scenarios.append("scanner error and retry")
        }

        do {
            let fixture = try Fixture(networks: { [first] })
            var selections = 0
            var closed = 0
            fixture.controller.onClose = { closed += 1 }
            fixture.controller.configure(port: 5998) { _ in selections += 1 }
            try fixture.search()
            let beforeCancel = fixture.scanner.cancellations
            try fixture.control("discoveryCancel", as: NSButton.self).performClick(nil)
            expect(fixture.scanner.cancellations == beforeCancel + 1, "Cancel invokes the fake cancellation contract")
            expect(closed == 1 && selections == 0 && !fixture.window.isVisible, "Cancel closes without choosing a server")
            expect(!fixture.scanner.publish([high], completed: 1, total: 2) && !fixture.scanner.finish([high]), "cancellation invalidates pending fake callbacks")
            expect(selections == 0, "canceling never calls onSelect")
            scenarios.append("cancel without selection or callback")
        }

        do {
            let scanner = FakeDiscovery()
            var owner: VNCDiscoveryController? = VNCDiscoveryController(scanner: scanner, networksProvider: { [first] })
            guard let window = owner?.window, let content = window.contentView else { throw HarnessError.missingWindow }
            window.ignoresMouseEvents = true
            window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
            window.orderBack(nil); window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
            content.layoutSubtreeIfNeeded()
            func find(_ id: String) -> NSView? {
                var pending = [content]
                while let view = pending.popLast() {
                    if view.identifier?.rawValue == id { return view }
                    pending.append(contentsOf: view.subviews)
                }
                return nil
            }
            guard let alias = find("discoveryAlias") as? NSTextField,
                  let search = find("discoverySearch") as? NSButton,
                  let table = find("discoveryResults") as? NSTableView,
                  let use = find("discoveryUseServer") as? NSButton else { throw HarnessError.missingControl("alias lifetime controls") }
            var received: DiscoveredVNCServer?
            var receivedAlias: String?
            var callbackObservedReleasedOwner = false
            var closeCalls = 0
            owner?.configure(port: 5999) { server, name in
                received = server; receivedAlias = name
                callbackObservedReleasedOwner = owner == nil
            }
            owner?.onClose = {
                closeCalls += 1
                alias.stringValue = "discarded by close"
                owner = nil
            }
            search.performClick(nil)
            scanner.finish([high])
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
            alias.stringValue = "  Release-safe alias  "
            expect(use.isEnabled, "lifetime scenario can explicitly select a found server")
            use.performClick(nil)
            expect(closeCalls == 1 && owner == nil, "onClose releases the external controller owner")
            expect(callbackObservedReleasedOwner, "selection callback runs after external owner release")
            expect(received == high && receivedAlias == "Release-safe alias", "selection receives the pre-close alias value after controls and ownership change")
            expect(!window.isVisible, "lifetime test closes only its owned offscreen window")
            window.orderOut(nil); window.close()
            scenarios.append("alias callback value survives onClose ownership release")
        }
    }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        guard !NSScreen.screens.isEmpty else {
            fputs("UNAVAILABLE: owned discovery UI tests require WindowServer access (exit 77).\n", stderr)
            exit(77)
        }
        do { try run() }
        catch { failures.append("Harness could not complete: \(error)") }
        let report: [String: Any] = [
            "status": failures.isEmpty ? "passed" : "failed", "checks": checks,
            "scenarios": scenarios, "failures": failures,
            "observations": observations,
            "network": "injected fake scanner and synthetic LAN plans only",
            "window": "test-owned offscreen windows; no activation or global events",
            "keychain": "not accessed",
        ]
        if CommandLine.arguments.count > 1 {
            do {
                let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
            } catch { fputs("Could not write discovery UI report: \(error)\n", stderr); exit(1) }
        }
        if failures.isEmpty { print("PASS: \(checks) native discovery UI checks; injected scanner only, no network or Keychain access.") }
        else {
            fputs("FAILED: \(failures.count) discovery UI checks.\n", stderr)
            for key in observations.keys.sorted() { fputs("\(key): \(observations[key]!)\n", stderr) }
        }
        exit(failures.isEmpty ? 0 : 1)
    }
}
