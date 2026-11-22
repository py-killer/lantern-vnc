// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// A narrow app-private interface. There is no item enumeration, arbitrary
/// Keychain service selection, ACL editing, or authentication-UI operation.
@objc protocol VaultProtocol {
    func read(host: String, port: Int, reply: @escaping (String?, Int32) -> Void)
    func save(host: String, port: Int, password: String, reply: @escaping (Int32) -> Void)
    func remove(host: String, port: Int, reply: @escaping (Int32) -> Void)
}

enum VaultConfiguration {
    static let serviceName = "local.lantern.vnc.credential-vault"
    static let passwordService = "local.lantern.vnc.password.vault.v1"
    static let mainIdentifier = "local.lantern.vnc"
    static let certificateInfoKey = "LanternVaultClientCertificateSHA1"

    static func requirement(identifier: String, certificateSHA1: String) -> String? {
        let certificate = certificateSHA1.lowercased()
        guard certificate.utf8.count == 40,
              certificate.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              [mainIdentifier, serviceName].contains(identifier) else { return nil }
        return "identifier \"\(identifier)\" and certificate leaf = H\"\(certificate)\""
    }
}
