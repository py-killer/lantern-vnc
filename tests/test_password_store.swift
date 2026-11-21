// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Security
import Darwin

private final class ApprovalFallbackStore: PasswordStorage {
    var reads = 0
    func read(host: String, port: UInt16) throws -> String? { reads += 1; return "synthetic-fallback" }
    func save(host: String, port: UInt16, password: String) throws { }
    func remove(host: String, port: UInt16) throws { }
}

private final class PromptPolicyProbe {
    var allowed = true
    var requireApproval = true
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
            if self.requireApproval && !self.allowed { return errSecInteractionNotAllowed }
            result?.pointee = Data("synthetic-approved".utf8) as CFData
            return errSecSuccess
        }
        operations.update = { query, _ in
            self.observed.append(("save", self.allowed, query as! [String: Any]))
            return self.requireApproval && !self.allowed ? errSecInteractionNotAllowed : errSecSuccess
        }
        operations.add = { query, _ in
            self.observed.append(("add", self.allowed, query as! [String: Any]))
            return self.requireApproval && !self.allowed ? errSecInteractionNotAllowed : errSecSuccess
        }
        operations.delete = { query in
            self.observed.append(("remove", self.allowed, query as! [String: Any]))
            return self.requireApproval && !self.allowed ? errSecInteractionNotAllowed : errSecSuccess
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
            do { try operation(); fatalError("Password store policy test: automatic operation must not request approval") }
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
        expect(probe.observed.allSatisfy { !$0.1 }, "every automatic operation is noninteractive")
        expect(probe.allowed, "automatic errors leave prior interaction state restored")
        let approved: PasswordStorage = store
        expect(try approved.readWithUserApproval(host: "EXAMPLE.INVALID", port: 5900) == "synthetic-approved", "explicit approval dispatches to concrete approved read")
        let explicit = probe.observed.last!
        expect(explicit.0 == "read" && explicit.1, "only explicit approval enables process interaction for a read")
        expect(explicit.2[kSecUseAuthenticationUI as String] as? String == kSecUseAuthenticationUIAllow as String, "explicit approval query permits authentication UI")
        expect(explicit.2[kSecAttrService as String] as? String == first[kSecAttrService as String] as? String &&
               explicit.2[kSecAttrAccount as String] as? String == first[kSecAttrAccount as String] as? String,
               "approved read keeps the exact service/account namespace")
        expect(explicit.2[kSecAttrAccess as String] == nil && explicit.2[kSecAttrAccessControl as String] == nil,
               "approval never rewrites item ACLs")
        probe.allowed = false
        let explicitlyConfigured = PasswordStore(service: service, allowAuthenticationUI: true, operations: probe.operations())
        expect(try explicitlyConfigured.read(host: "example.invalid", port: 5900) == "synthetic-approved", "explicit allowAuthenticationUI initializer remains supported")
        expect(!probe.allowed, "approved operation restores a previously disabled process policy")
        let fallback = ApprovalFallbackStore()
        let fake: PasswordStorage = fallback
        expect(try fake.readWithUserApproval(host: "example.invalid", port: 5900) == "synthetic-fallback" && fallback.reads == 1,
               "protocol default approval path delegates to fake read")
        let unavailable = PromptPolicyProbe()
        unavailable.getStatus = errSecNotAvailable
        do {
            _ = try PasswordStore(service: service, operations: unavailable.operations()).read(host: "example.invalid", port: 5900)
            fatalError("Password store policy test: unavailable guard must stop before reading")
        } catch PasswordStoreError.keychain(let status) { expect(status == errSecNotAvailable, "policy guard error is surfaced") }
        expect(unavailable.observed.isEmpty, "failed interaction guard never touches an item")
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
        let store = PasswordStore(service: service, allowAuthenticationUI: false)
        let other = PasswordStore(service: otherService, allowAuthenticationUI: false)
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
        let reloaded = PasswordStore(service: service, allowAuthenticationUI: false)
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
