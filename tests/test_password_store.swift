// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Security
import Darwin

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
