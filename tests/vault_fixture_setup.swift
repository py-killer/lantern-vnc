// SPDX-License-Identifier: GPL-2.0-or-later
// Creates/deletes a newly owned test Keychain only. Input is private JSON via
// stdin so its generated fixture password never appears in command arguments.
import Foundation
import Security
import Darwin

let data = FileHandle.standardInput.readDataToEndOfFile()
guard let request = try JSONSerialization.jsonObject(with: data) as? [String:String],
      let action = request["action"], let path = request["path"],
      path.contains("/vault-xpc-tests/fixtures.noindex/run-") else { exit(2) }
var previous = DarwinBoolean(false)
guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess,
      SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { exit(3) }
defer { _ = SecKeychainSetUserInteractionAllowed(previous.boolValue) }
var keychain: SecKeychain?
let status: OSStatus
if action == "create", let password = request["password"] {
    status = password.withCString { SecKeychainCreate(path, UInt32(password.utf8.count), $0, false, nil, &keychain) }
} else if action == "delete" {
    let opened = SecKeychainOpen(path, &keychain)
    status = opened == errSecSuccess && keychain != nil ? SecKeychainDelete(keychain!) : opened
} else { exit(2) }
print("owned-keychain-\(action):\(status)")
exit(status == errSecSuccess ? 0 : 1)
