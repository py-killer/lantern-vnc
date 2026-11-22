// SPDX-License-Identifier: GPL-2.0-or-later
// Owns only a fresh UUID fixture item in the legacy namespace. Never accepts
// an owner endpoint or prints any credential value. The same binary cleans it.
import Foundation
import Security
import Darwin

@main struct VaultLoginSeed {
    static func main() {
        guard CommandLine.arguments.count==3 else { exit(2) }
        let mode=CommandLine.arguments[1],host=CommandLine.arguments[2]
        guard host.range(of:"^synthetic-vault-[a-f0-9]{32}\\.invalid$",options:.regularExpression) != nil,
              SecKeychainSetUserInteractionAllowed(false)==errSecSuccess else { exit(2) }
        let store=PasswordStore(service:VaultV2Configuration.legacyPasswordService)
        do {
            switch mode {
            case "write": try store.save(host:host,port:5900,password:"synthetic-public-vault-🐯-credential")
            case "read": guard try store.read(host:host,port:5900)=="synthetic-public-vault-🐯-credential" else { exit(1) }
            case "delete": try store.remove(host:host,port:5900);guard try store.read(host:host,port:5900)==nil else { exit(1) }
            default: exit(2)
            }
            print("PASS: owned legacy UUID fixture \(mode)")
        } catch { fputs("FAIL: owned UUID fixture: \(error.localizedDescription)\n",stderr);exit(1) }
    }
}
