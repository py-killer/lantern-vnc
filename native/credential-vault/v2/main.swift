// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Security
import Darwin

/// This generation joins the caller's existing login security session. Its
/// normal operations own only the v2 namespace; v1 access is read-only and
/// explicit. Neither an old protected item nor the v1 helper is altered.
final class CredentialVault: NSObject, VaultV2Protocol {
    private let storage = PasswordStore(service: VaultV2Configuration.passwordService)
    private let legacy = PasswordStore(service: VaultV2Configuration.legacyPasswordService)

    private func endpoint(_ host: String, _ port: Int) throws -> UInt16 {
        guard (1...65535).contains(port) else { throw PasswordStoreError.invalidEndpoint }
        let value = UInt16(port)
        _ = try PasswordStore.account(host: host, port: value)
        return value
    }
    private func status(_ error: Error) -> OSStatus {
        switch error {
        case PasswordStoreError.keychain(let value): return value
        case PasswordStoreError.invalidEndpoint, PasswordStoreError.invalidService: return errSecParam
        case PasswordStoreError.invalidStoredData: return errSecDecode
        default: return errSecInternalComponent
        }
    }
    func read(host: String, port: Int, reply: @escaping (String?, Int32) -> Void) {
        do { reply(try storage.read(host: host, port: endpoint(host, port)), errSecSuccess) }
        catch { reply(nil, status(error)) }
    }
    func readLegacy(host: String, port: Int, reply: @escaping (String?, Int32) -> Void) {
        do { reply(try legacy.read(host: host, port: endpoint(host, port)), errSecSuccess) }
        catch { reply(nil, status(error)) }
    }
    func save(host: String, port: Int, password: String, reply: @escaping (Int32) -> Void) {
        guard password.utf8.count <= 65536 else { reply(errSecParam); return }
        do { try storage.save(host: host, port: endpoint(host, port), password: password); reply(errSecSuccess) }
        catch { reply(status(error)) }
    }
    func remove(host: String, port: Int, reply: @escaping (Int32) -> Void) {
        do { try storage.remove(host: host, port: endpoint(host, port)); reply(errSecSuccess) }
        catch { reply(status(error)) }
    }
}

final class VaultListener: NSObject, NSXPCListenerDelegate {
    private let vault = CredentialVault()
    private let requirement: String
    init(requirement: String) { self.requirement = requirement }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == geteuid() else { return false }
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: VaultV2Protocol.self)
        connection.exportedObject = vault
        connection.resume()
        return true
    }
}

func failClosed() -> Never {
    fputs("Lantern credential vault is unavailable. Authentication dialogs are disabled.\n", stderr)
    exit(1)
}
// Joining the login session does not grant permission to show authentication
// UI. The process-wide policy is disabled before every Security item operation.
guard SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { failClosed() }
guard let configuration = Bundle.main.object(forInfoDictionaryKey: "XPCService") as? [String: Any],
      configuration["JoinExistingSession"] as? Bool == true,
      let pin = Bundle.main.object(forInfoDictionaryKey: VaultConfiguration.certificateInfoKey) as? String,
      let requirement = VaultConfiguration.requirement(identifier: VaultConfiguration.mainIdentifier, certificateSHA1: pin)
else { failClosed() }
var validatedRequirement: SecRequirement?
guard SecRequirementCreateWithString(requirement as CFString, [], &validatedRequirement) == errSecSuccess else { failClosed() }
let delegate = VaultListener(requirement: requirement)
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
