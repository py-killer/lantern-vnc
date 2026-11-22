// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// The v1 protocol and its signed helper remain frozen. A separate read-only
/// migration operation lets the main app apply its existing intent/tombstone
/// guards instead of implicitly reviving a v1 item after a v2 deletion.
@objc protocol VaultV2Protocol: VaultProtocol {
    func readLegacy(host: String, port: Int, reply: @escaping (String?, Int32) -> Void)
}

enum VaultV2Configuration {
    static let connectionServiceName = "local.lantern.vnc.credential-vault-v2"
    static let bundleName = "LanternCredentialVaultV2.xpc"
    static let codeIdentifier = "local.lantern.vnc.credential-vault"
    static let passwordService = "local.lantern.vnc.password.vault.v2"
    static let legacyPasswordService = "local.lantern.vnc.password.vault.v1"
}
