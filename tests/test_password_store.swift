// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Security
import Darwin

private final class PromptPolicyProbe {
    var allowed = true
    var requiresInteraction = true
    var readStatus: OSStatus?
    var observed: [(String, Bool, [String: Any])] = []
    var sets: [Bool] = []
    var getStatus = errSecSuccess
    var setStatus = errSecSuccess
    func operations() -> PasswordStore.KeychainOperations {
        var operations = PasswordStore.KeychainOperations()
        operations.getInteractionAllowed = { value in
            value.pointee = DarwinBoolean(self.allowed)
            return self.getStatus
        }
        operations.setInteractionAllowed = { enabled in
            self.sets.append(enabled)
            if self.setStatus == errSecSuccess { self.allowed = enabled }
            return self.setStatus
        }
        operations.copyMatching = { query, result in
            self.observed.append(("read", self.allowed, query as! [String: Any]))
            // Deliberately ignores the query flag, just like legacy paths can.
            if let status = self.readStatus { return status }
            if self.requiresInteraction && !self.allowed { return errSecInteractionNotAllowed }
            result?.pointee = Data("synthetic-noninteractive".utf8) as CFData
            return errSecSuccess
        }
        operations.update = { query, _ in
            self.observed.append(("save", self.allowed, query as! [String: Any]))
            return self.requiresInteraction && !self.allowed ? errSecInteractionNotAllowed : errSecSuccess
        }
        operations.add = { query, _ in
            self.observed.append(("add", self.allowed, query as! [String: Any]))
            return self.requiresInteraction && !self.allowed ? errSecInteractionNotAllowed : errSecSuccess
        }
        operations.delete = { query in
            self.observed.append(("remove", self.allowed, query as! [String: Any]))
            return self.requiresInteraction && !self.allowed ? errSecInteractionNotAllowed : errSecSuccess
        }
        return operations
    }
}

@main
struct PasswordStoreTests {
    private static var checks = 0
    private static func expect(_ condition: Bool, _ message: String) {
        checks += 1
        guard condition else { fatalError("Password store test: \(message)") }
    }
    private static func invalid(_ operation: () throws -> Void) {
        checks += 1
        do { try operation(); fatalError("Password store test: expected endpoint/configuration rejection") }
        catch PasswordStoreError.invalidEndpoint { }
        catch PasswordStoreError.invalidService { }
        catch { fatalError("Password store test: unexpected validation error type") }
    }

    static func main() {
        do {
            try validationTests()
            try promptPolicyTests()
            print("PASS: \(checks) endpoint/configuration/error privacy checks; no Keychain access yet.")
            if CommandLine.arguments.contains("--policy-only") { return }
            try integrationTests()
            print("PASS: \(checks) total password-store checks, including isolated login-Keychain CRUD and cleanup.")
        } catch PasswordStoreError.keychain(let status) {
            let unavailable: Set<OSStatus> = [errSecNotAvailable, errSecNoSuchKeychain,
                errSecInvalidKeychain, errSecNoDefaultKeychain, errSecInteractionNotAllowed,
                errSecAuthFailed, errSecUserCanceled, errSecMissingEntitlement]
            if unavailable.contains(status) {
                print("NOT RUN: real Keychain checks unavailable without interaction (OSStatus \(status)); not a passing integration result.")
                exit(77)
            }
            print("FAIL: isolated Keychain check returned OSStatus \(status).")
            exit(1)
        } catch {
            print("FAIL: password-store checks did not complete (\(type(of: error))).")
            exit(1)
        }
    }

    private static func promptPolicyTests() throws {
        let service = "local.lantern.vnc.policy-tests.\(UUID().uuidString)"
        let probe = PromptPolicyProbe()
        let store = PasswordStore(service: service, operations: probe.operations())
        func denied(_ operation: () throws -> Void) {
            checks += 1
            do { try operation(); fatalError("Password store policy test: inaccessible item must fail without authentication UI") }
            catch PasswordStoreError.keychain(let status) {
                expect(status == errSecInteractionNotAllowed, "inaccessible item reports interaction-not-allowed")
            } catch { fatalError("Password store policy test: unexpected error") }
        }
        denied { _ = try store.read(host: "example.invalid", port: 5900) }
        expect(probe.observed.count == 1 && probe.observed[0].1 == false, "default read disables process-local legacy interaction")
        expect(probe.allowed && probe.sets == [false, true], "failed default read restores prior process policy")
        let first = probe.observed[0].2
        expect(first[kSecUseAuthenticationUI as String] as? String == kSecUseAuthenticationUIFail as String, "default query also requests no authentication UI")
        denied { try store.save(host: "example.invalid", port: 5900, password: "synthetic-write") }
        denied { try store.remove(host: "example.invalid", port: 5900) }
        expect(probe.observed.map { $0.0 } == ["read", "save", "remove"], "denied read/save/remove neither adds nor migrates an item")
        expect(probe.observed.allSatisfy { !$0.1 }, "every read/save/remove operation is noninteractive")
        expect(probe.allowed, "operation errors restore prior process policy after all item access ends")
        for request in probe.observed.map({ $0.2 }) {
            expect(request[kSecUseAuthenticationUI as String] as? String == kSecUseAuthenticationUIFail as String,
                   "all operations reject authentication UI at query level")
            expect(request[kSecAttrAccess as String] == nil && request[kSecAttrAccessControl as String] == nil,
                   "failed noninteractive access never rewrites item ACLs")
        }
        probe.requiresInteraction = false; probe.allowed = false
        expect(try store.read(host: "EXAMPLE.INVALID", port: 5900) == "synthetic-noninteractive", "accessible credentials still read without interaction")
        try store.save(host: "example.invalid", port: 5900, password: "synthetic-write")
        try store.remove(host: "example.invalid", port: 5900)
        expect(!probe.allowed && probe.observed.suffix(3).allSatisfy { !$0.1 },
               "successful operations never enable a previously disabled policy")
        expect(probe.observed.last!.2[kSecAttrService as String] as? String == first[kSecAttrService as String] as? String &&
               probe.observed.last!.2[kSecAttrAccount as String] as? String == first[kSecAttrAccount as String] as? String,
               "success and failure keep the same credential namespace")
        for status in [errSecAuthFailed, errSecUserCanceled, errSecNotAvailable, errSecMissingEntitlement] {
            probe.readStatus = status
            do { _ = try store.read(host:"example.invalid",port:5900); fatalError("Expected synthetic access failure") }
            catch PasswordStoreError.keychain(let result) { expect(result == status, "access failure is surfaced without another access attempt") }
            expect(!probe.allowed && probe.observed.last?.1 == false, "all failure kinds stay noninteractive")
        }
        probe.readStatus = nil
        let insertion = PromptPolicyProbe(); insertion.requiresInteraction = false
        var insertionOperations = insertion.operations()
        insertionOperations.update = { request, _ in
            insertion.observed.append(("save",insertion.allowed,request as! [String:Any])); return errSecItemNotFound
        }
        try PasswordStore(service:service,operations:insertionOperations).save(host:"example.invalid",port:5900,password:"synthetic-new")
        expect(insertion.observed.map { $0.0 } == ["save","add"] && insertion.observed.allSatisfy { !$0.1 },
               "creation path also keeps both update and add noninteractive")
        expect(insertion.observed.last!.2[kSecUseAuthenticationUI as String] as? String == kSecUseAuthenticationUIFail as String,
               "new-item addition rejects authentication UI")
        let unavailable = PromptPolicyProbe()
        unavailable.getStatus = errSecNotAvailable
        do {
            _ = try PasswordStore(service: service, operations: unavailable.operations()).read(host: "example.invalid", port: 5900)
            fatalError("Password store policy test: unavailable guard must stop before reading")
        } catch PasswordStoreError.keychain(let status) { expect(status == errSecNotAvailable, "policy guard error is surfaced") }
        expect(unavailable.observed.isEmpty, "failed interaction guard never touches an item")
        let cannotDisable = PromptPolicyProbe(); cannotDisable.setStatus = errSecNotAvailable
        do {
            _ = try PasswordStore(service:service,operations:cannotDisable.operations()).read(host:"example.invalid",port:5900)
            fatalError("Expected unavailable noninteractive policy")
        } catch PasswordStoreError.keychain(let status) { expect(status == errSecNotAvailable, "inability to disable interaction fails closed") }
        expect(cannotDisable.observed.isEmpty && cannotDisable.sets == [false], "failed policy setup never attempts credential access")
        let concurrent = PromptPolicyProbe(); concurrent.requiresInteraction = false
        let shared = PasswordStore(service:service,operations:concurrent.operations())
        let group = DispatchGroup(), failures = NSLock()
        var failedReads = 0
        for _ in 0..<4 {
            group.enter(); DispatchQueue.global().async {
                defer { group.leave() }
                for _ in 0..<8 {
                    do { _ = try shared.read(host:"example.invalid",port:5900) }
                    catch { failures.lock();failedReads += 1;failures.unlock() }
                }
            }
        }
        expect(group.wait(timeout:.now()+5) == .success, "serialized synthetic reads complete within a bounded interval")
        expect(failedReads == 0 && concurrent.observed.count == 32 && concurrent.observed.allSatisfy { !$0.1 },
               "parallel callers never observe another call restoring interaction early")
        expect(concurrent.allowed, "serialized reads restore the original policy only after each operation")
    }

    private static func validationTests() throws {
        expect(try PasswordStore.account(host: " EXAMPLE.INVALID \n", port: 5900) ==
                   PasswordStore.account(host: "example.invalid", port: 5900), "trimmed/case-folded endpoint")
        expect(try PasswordStore.account(host: "[2001:DB8::1]", port: 5900) ==
                   PasswordStore.account(host: "2001:db8::1", port: 5900), "bracketed IPv6 alias")
        expect(try PasswordStore.account(host: "2001:db8::1", port: 5900) !=
                   PasswordStore.account(host: "2001:db8::1", port: 5901), "IPv6 ports isolated")
        expect(try PasswordStore.account(host: "ÄBC.invalid", port: 5900) ==
                   PasswordStore.account(host: "äbc.invalid", port: 5900), "Unicode host case folding")
        expect(try PasswordStore.account(host: "fe80::1%en0", port: 5900) !=
                   PasswordStore.account(host: "fe80::1%en1", port: 5900), "IPv6 scopes isolated")
        expect(try PasswordStore.account(host: "a.invalid", port: 12) !=
                   PasswordStore.account(host: "a1.invalid", port: 2), "tuple boundaries distinct")
        for host in ["", " \n", "host/path", "vnc://host", "host name", "host\tname",
                     "host\u{0}name", "host@name", "host?x", "[::1", "::1]", "local:5900",
                     "[::1]:5900", "999.1.1.1", "..", "-bad.invalid", "::1%"] {
            invalid { _ = try PasswordStore.account(host: host, port: 5900) }
        }
        invalid { _ = try PasswordStore.account(host: "valid.invalid", port: 0) }
        invalid { _ = try PasswordStore(service: "").read(host: "valid.invalid", port: 5900) }
        invalid { try PasswordStore(service: " ").save(host: "valid.invalid", port: 5900, password: "synthetic") }
        let errorText = PasswordStoreError.keychain(errSecAuthFailed).localizedDescription
        expect(errorText.contains(String(errSecAuthFailed)), "OSStatus included without credential values")
        expect(!errorText.contains("example.invalid") && !errorText.contains("synthetic"), "error privacy")
        for status in [errSecInteractionNotAllowed,errSecAuthFailed,errSecUserCanceled,errSecNotAvailable,errSecMissingEntitlement] {
            let text=PasswordStoreError.keychain(status).localizedDescription.lowercased()
            expect(!text.contains("unlock") && !text.contains("enter the password") && !text.contains("try again") && !text.contains("needs confirmation"),
                   "failure copy never asks for credentials or approval")
        }
    }

    private static func integrationTests() throws {
        // These flags affect this test process only. Never unlock a keychain,
        // automate a security prompt, or query any pre-existing password item.
        var previouslyAllowed = DarwinBoolean(false)
        let prior = SecKeychainGetUserInteractionAllowed(&previouslyAllowed)
        guard prior == errSecSuccess else { throw PasswordStoreError.keychain(prior) }
        let disabled = SecKeychainSetUserInteractionAllowed(false)
        guard disabled == errSecSuccess else { throw PasswordStoreError.keychain(disabled) }
        defer { _ = SecKeychainSetUserInteractionAllowed(previouslyAllowed.boolValue) }
        var defaultKeychain: SecKeychain?
        let available = SecKeychainCopyDefault(&defaultKeychain)
        guard available == errSecSuccess else { throw PasswordStoreError.keychain(available) }

        let service = "local.lantern.vnc.password-tests.\(UUID().uuidString)"
        let otherService = service + ".isolated"
        let store = PasswordStore(service: service)
        let other = PasswordStore(service: otherService)
        let endpoints: [(String, UInt16)] = [("example.invalid", 5900), ("example.invalid", 5901),
            ("other.invalid", 5900), ("2001:db8::1", 5900), ("invalid-data.invalid", 5900)]
        defer {
            // Delete exact accounts in only the two UUID-scoped test services.
            for (host, port) in endpoints {
                try? store.remove(host: host, port: port)
                try? other.remove(host: host, port: port)
            }
        }
        expect(try store.read(host: "example.invalid", port: 5900) == nil, "missing value is nil")
        try store.remove(host: "example.invalid", port: 5900)
        try store.save(host: " EXAMPLE.INVALID ", port: 5900, password: "synthetic-first")
        expect(try store.read(host: "example.invalid", port: 5900) == "synthetic-first", "create and canonical read")
        let unicode = "Sëcret 🧪\n密碼\u{0}"
        try store.save(host: "example.invalid", port: 5900, password: unicode)
        expect(try store.read(host: "example.invalid", port: 5900) == unicode, "update preserves UTF-8")
        let reloaded = PasswordStore(service: service)
        expect(try reloaded.read(host: "EXAMPLE.INVALID", port: 5900) == unicode, "new instance reads Keychain")
        expect(try store.read(host: "example.invalid", port: 5901) == nil, "port isolation before save")
        expect(try store.read(host: "other.invalid", port: 5900) == nil, "host isolation before save")
        expect(try other.read(host: "example.invalid", port: 5900) == nil, "service isolation before save")
        try store.save(host: "example.invalid", port: 5901, password: "synthetic-port")
        try store.save(host: "other.invalid", port: 5900, password: "synthetic-host")
        try other.save(host: "example.invalid", port: 5900, password: "synthetic-service")
        try store.save(host: "[2001:DB8::1]", port: 5900, password: "synthetic-ipv6")
        expect(try store.read(host: "2001:db8::1", port: 5900) == "synthetic-ipv6", "IPv6 canonical CRUD")
        try store.remove(host: " EXAMPLE.INVALID ", port: 5900)
        expect(try store.read(host: "example.invalid", port: 5900) == nil, "removed value is absent")
        try store.remove(host: "example.invalid", port: 5900)
        expect(try other.read(host: "example.invalid", port: 5900) == "synthetic-service", "delete does not cross service")
        expect(try store.read(host: "example.invalid", port: 5901) == "synthetic-port", "delete does not cross port")
        expect(try store.read(host: "other.invalid", port: 5900) == "synthetic-host", "delete does not cross host")
        try store.save(host: "example.invalid", port: 5900, password: "")
        expect(try store.read(host: "example.invalid", port: 5900) == "", "empty stored string differs from missing")

        let corrupt: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: try PasswordStore.account(host: "invalid-data.invalid", port: 5900),
            kSecUseDataProtectionKeychain as String: false, kSecAttrSynchronizable as String: false,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
            kSecValueData as String: Data([0xff, 0xfe])]
        let addStatus = SecItemAdd(corrupt as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw PasswordStoreError.keychain(addStatus) }
        do { _ = try store.read(host: "invalid-data.invalid", port: 5900)
            fatalError("Password store test: invalid UTF-8 must be rejected")
        } catch PasswordStoreError.invalidStoredData { checks += 1 }
        for (host, port) in endpoints {
            try store.remove(host: host, port: port)
            try other.remove(host: host, port: port)
            expect(try store.read(host: host, port: port) == nil, "owned item removed")
            expect(try other.read(host: host, port: port) == nil, "isolated owned item removed")
        }
    }
}
