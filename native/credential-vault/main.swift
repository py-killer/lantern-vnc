// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Security
import Darwin

#if VAULT_HARNESS
private enum VaultAudit {
    static let lock = NSLock()
    static func event(_ name: String) {
        guard let path = Bundle.main.object(forInfoDictionaryKey: "LanternVaultTestLifecycleFile") as? String else { return }
        lock.lock(); defer { lock.unlock() }
        let line = "\(getpid()) \(name)\n"
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let file = FileHandle(forWritingAtPath: path) else { return }
        defer { try? file.close() }
        _ = try? file.seekToEnd(); try? file.write(contentsOf: Data(line.utf8))
    }
}
#endif

/// This service must retain the exact same signed bundle across main-app
/// updates. Its default Keychain ACL and partition remain owned by this code.
/// Changing or rebuilding it requires a separately reviewed migration plan.
final class CredentialVault: NSObject, VaultProtocol {
    private let storage: PasswordStorage
    init(storage: PasswordStorage) { self.storage = storage }

    private func endpoint(_ host: String, _ port: Int) throws -> UInt16 {
        guard (1...65535).contains(port) else { throw PasswordStoreError.invalidEndpoint }
        let value = UInt16(port)
        _ = try PasswordStore.account(host: host, port: value)
        return value
    }

    private func status(_ error: Error) -> OSStatus {
        let result: OSStatus
        switch error {
        case PasswordStoreError.keychain(let value): result = value
        case PasswordStoreError.invalidEndpoint, PasswordStoreError.invalidService: result = errSecParam
        case PasswordStoreError.invalidStoredData: result = errSecDecode
        default: result = errSecInternalComponent
        }
#if VAULT_HARNESS
        VaultAudit.event("status:\(result)")
#endif
        return result
    }

    func read(host: String, port: Int, reply: @escaping (String?, Int32) -> Void) {
#if VAULT_HARNESS
        VaultAudit.event("read")
#endif
        do { reply(try storage.read(host: host, port: endpoint(host, port)), errSecSuccess) }
        catch { reply(nil, status(error)) }
    }

    func save(host: String, port: Int, password: String, reply: @escaping (Int32) -> Void) {
#if VAULT_HARNESS
        VaultAudit.event("save")
#endif
        guard password.utf8.count <= 65536 else { reply(errSecParam); return }
        do { try storage.save(host: host, port: endpoint(host, port), password: password); reply(errSecSuccess) }
        catch { reply(status(error)) }
    }

    func remove(host: String, port: Int, reply: @escaping (Int32) -> Void) {
#if VAULT_HARNESS
        VaultAudit.event("remove")
#endif
        do { try storage.remove(host: host, port: endpoint(host, port)); reply(errSecSuccess) }
        catch { reply(status(error)) }
    }
}

final class VaultListener: NSObject, NSXPCListenerDelegate {
    private let vault: CredentialVault
    private let requirement: String
    init(vault: CredentialVault, requirement: String) {
        self.vault = vault; self.requirement = requirement
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == geteuid() else { return false }
        // The OS checks peer identity continuously, including messages sent
        // through a forwarded connection. A bundle ID, path, or PID alone is
        // deliberately insufficient to authorize access to credentials.
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: VaultProtocol.self)
        connection.exportedObject = vault
        connection.resume()
        return true
    }
}

func failClosed() -> Never {
    fputs("Lantern credential vault is unavailable. Authentication dialogs are disabled.\n", stderr)
    exit(1)
}

// No Security operation that can access an item precedes this policy. This
// dedicated process never restores interaction=true; each PasswordStore call
// additionally serializes and checks its own noninteractive policy.
guard SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { failClosed() }
guard let pin = Bundle.main.object(forInfoDictionaryKey: VaultConfiguration.certificateInfoKey) as? String,
      let requirement = VaultConfiguration.requirement(identifier: VaultConfiguration.mainIdentifier, certificateSHA1: pin)
else { failClosed() }
var validatedRequirement: SecRequirement?
guard SecRequirementCreateWithString(requirement as CFString, [], &validatedRequirement) == errSecSuccess else { failClosed() }

let storage: PasswordStorage
#if VAULT_HARNESS
// This branch is absent from public builds. A test supplies its own Keychain;
// every query and mutation is constrained to that explicit owned file.
guard let path = Bundle.main.object(forInfoDictionaryKey: "LanternVaultTestKeychain") as? String ?? ProcessInfo.processInfo.environment["LANTERN_VAULT_TEST_KEYCHAIN"],
      let testService = Bundle.main.object(forInfoDictionaryKey: "LanternVaultTestService") as? String ?? ProcessInfo.processInfo.environment["LANTERN_VAULT_TEST_SERVICE"],
      testService.hasPrefix("local.lantern.synthetic-lab.") else { failClosed() }
var testKeychain: SecKeychain?
guard SecKeychainOpen(path, &testKeychain) == errSecSuccess, let testKeychain = testKeychain else { failClosed() }
var testStatus: SecKeychainStatus = 0
let statusResult = SecKeychainGetStatus(testKeychain, &testStatus)
VaultAudit.event("keychain-status:\(statusResult):\(testStatus)")
guard path.contains("/vault-xpc-tests/fixtures.noindex/run-"),
      let passwordFile = Bundle.main.object(forInfoDictionaryKey: "LanternVaultTestKeychainPasswordFile") as? String,
      URL(fileURLWithPath: passwordFile).deletingLastPathComponent() == URL(fileURLWithPath: path).deletingLastPathComponent(),
      let testPassword = try? String(contentsOfFile: passwordFile, encoding: .utf8) else { failClosed() }
let unlocked = testPassword.withCString { SecKeychainUnlock(testKeychain, UInt32(testPassword.utf8.count), $0, true) }
VaultAudit.event("unlock-owned-keychain:\(unlocked)")
guard unlocked == errSecSuccess else { failClosed() }
var operations = PasswordStore.KeychainOperations()
func isolated(_ input: CFDictionary, adding: Bool = false) -> CFDictionary {
    var query = input as! [String: Any]
    if adding {
        query.removeValue(forKey: kSecMatchSearchList as String)
        query[kSecUseKeychain as String] = testKeychain
    } else { query[kSecMatchSearchList as String] = [testKeychain] }
    return query as CFDictionary
}
operations.copyMatching = { SecItemCopyMatching(isolated($0), $1) }
operations.update = { SecItemUpdate(isolated($0), $1) }
operations.add = { SecItemAdd(isolated($0, adding: true), $1) }
operations.delete = { SecItemDelete(isolated($0)) }
storage = PasswordStore(service: testService, operations: operations)
VaultAudit.event("start")
#else
storage = PasswordStore(service: VaultConfiguration.passwordService)
#endif

let delegate = VaultListener(vault: CredentialVault(storage: storage), requirement: requirement)
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
