// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Security
import Darwin

protocol PasswordStorage {
    func read(host: String, port: UInt16) throws -> String?
    func save(host: String, port: UInt16, password: String) throws
    func remove(host: String, port: UInt16) throws
}

enum PasswordStoreError: LocalizedError {
    case invalidEndpoint
    case invalidService
    case invalidStoredData
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "Enter a valid server host and TCP port before using saved passwords."
        case .invalidService:
            return "The Keychain password store is not configured correctly."
        case .invalidStoredData:
            return "The saved Keychain password could not be read. Remove it and save the password again."
        case .keychain(let status):
            let explanation: String
            switch status {
            case errSecInteractionNotAllowed:
                explanation = "Keychain access needs confirmation or an unlocked keychain. Unlock it and try again."
            case errSecAuthFailed:
                explanation = "Keychain access was not authorized. Check access permissions and try again."
            case errSecUserCanceled:
                explanation = "Keychain access was canceled. You can enter the password without saving it."
            case errSecNotAvailable, errSecNoSuchKeychain, errSecInvalidKeychain:
                explanation = "macOS Keychain is unavailable. You can enter the password without saving it."
            case errSecMissingEntitlement:
                explanation = "This app could not access macOS Keychain with its current signing permissions."
            default:
                explanation = "macOS Keychain could not complete the password operation."
            }
            // Never interpolate an endpoint, password, query, or returned data.
            return "\(explanation) (OSStatus \(status).)"
        }
    }
}

/// Generic passwords in the classic macOS login Keychain, explicitly selected
/// so the current ad hoc signed app can use it without a paid signing identity.
/// The OS encrypts the item and enforces the keychain's lock/access controls.
/// This does NOT claim Data Protection's WhenUnlockedThisDeviceOnly semantics:
/// that attribute is ignored by the classic keychain and is deliberately absent.
/// Synchronization is disabled; plaintext passwords are never written to defaults.
final class PasswordStore: PasswordStorage {
    static let defaultService = "local.lantern.vnc.password"
    private let service: String
    private let allowAuthenticationUI: Bool

    init(service: String = PasswordStore.defaultService, allowAuthenticationUI: Bool = true) {
        self.service = service
        self.allowAuthenticationUI = allowAuthenticationUI
    }

    func read(host: String, port: UInt16) throws -> String? {
        var request = try query(host: host, port: port)
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        request[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw PasswordStoreError.keychain(status) }
        guard let data = result as? Data, let password = String(data: data, encoding: .utf8) else {
            throw PasswordStoreError.invalidStoredData
        }
        return password
    }

    func save(host: String, port: UInt16, password: String) throws {
        let request = try query(host: host, port: port)
        let attributes = [kSecValueData as String: Data(password.utf8)]
        var status = SecItemUpdate(request as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addition = request
            addition[kSecValueData as String] = Data(password.utf8)
            addition[kSecAttrLabel as String] = "Lantern VNC password"
            status = SecItemAdd(addition as CFDictionary, nil)
            if status == errSecDuplicateItem {
                // Another caller may have inserted this exact endpoint meanwhile.
                status = SecItemUpdate(request as CFDictionary, attributes as CFDictionary)
            }
        }
        guard status == errSecSuccess else { throw PasswordStoreError.keychain(status) }
    }

    func remove(host: String, port: UInt16) throws {
        let status = SecItemDelete(try query(host: host, port: port) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PasswordStoreError.keychain(status)
        }
    }

    private func query(host: String, port: UInt16) throws -> [String: Any] {
        guard !service.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              service.utf8.count <= 512,
              !service.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw PasswordStoreError.invalidService
        }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: try Self.account(host: host, port: port),
            kSecUseDataProtectionKeychain as String: false,
            kSecAttrSynchronizable as String: false,
            kSecUseAuthenticationUI as String: allowAuthenticationUI
                ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail,
        ]
    }

    /// UTF-8 length-prefixing keeps IPv6 punctuation separate from the TCP port.
    /// Endpoint normalization is deterministic and never performs DNS/network I/O.
    static func account(host: String, port: UInt16) throws -> String {
        guard port > 0 else { throw PasswordStoreError.invalidEndpoint }
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        // Check before Unicode folding, which can remove an embedded NUL.
        guard !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw PasswordStoreError.invalidEndpoint
        }
        var address = trimmed.precomposedStringWithCanonicalMapping
            .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
        guard !address.isEmpty, address.utf8.count <= 255,
              address.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              address.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw PasswordStoreError.invalidEndpoint
        }
        if address.hasPrefix("[") && address.hasSuffix("]") {
            address = String(address.dropFirst().dropLast())
            guard address.contains(":") else { throw PasswordStoreError.invalidEndpoint }
        }
        if address.contains(":") {
            let scoped = address.split(separator: "%", omittingEmptySubsequences: false)
            guard scoped.count == 1 || (scoped.count == 2 && !scoped[1].isEmpty &&
                  scoped[1].unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "_.-".unicodeScalars.contains($0) })) else {
                throw PasswordStoreError.invalidEndpoint
            }
            var ipv6 = in6_addr()
            guard String(scoped[0]).withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 else {
                throw PasswordStoreError.invalidEndpoint
            }
        } else {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
            guard address.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
                throw PasswordStoreError.invalidEndpoint
            }
            let withoutFinalDot = address.hasSuffix(".") ? String(address.dropLast()) : address
            let labels = withoutFinalDot.split(separator: ".", omittingEmptySubsequences: false)
            guard !labels.isEmpty, labels.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 63 &&
                  !$0.hasPrefix("-") && !$0.hasSuffix("-") }) else {
                throw PasswordStoreError.invalidEndpoint
            }
            if address.contains(".") && address.allSatisfy({ "0123456789.".contains($0) }) {
                guard labels.count == 4, labels.allSatisfy({ UInt8($0) != nil }) else {
                    throw PasswordStoreError.invalidEndpoint
                }
            }
        }
        return "v1|\(address.utf8.count)|\(address)|\(port)"
    }
}
