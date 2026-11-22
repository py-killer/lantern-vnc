// SPDX-License-Identifier: GPL-2.0-or-later
// PUBLIC helper/default-login proof. UUID endpoints and known fake values only.
import Foundation
import Security
import Darwin

@main struct VaultLoginHarness {
    static func main() {
        let build = "LANTERN_LOGIN_BUILD"
        guard CommandLine.arguments.count == 3 else { exit(2) }
        let action=CommandLine.arguments[1],host=CommandLine.arguments[2]
        guard host.hasPrefix("synthetic-vault-"),host.hasSuffix(".invalid") else { exit(2) }
        guard SecKeychainSetUserInteractionAllowed(false)==errSecSuccess else { exit(3) }
        let transport=XPCVaultTransport(timeout:3)
        let secret="synthetic-public-vault-🐯-credential"
        do {
            switch action {
            case "write":
                try transport.save(host:host,port:5900,password:secret)
                guard try transport.read(host:host.uppercased(),port:5900)==secret else { exit(1) }
            case "read": guard try transport.read(host:host,port:5900)==secret else { exit(1) }
            case "update":
                try transport.save(host:host,port:5901,password:secret+"-other-port")
                guard try transport.read(host:host,port:5900)==secret,
                      try transport.read(host:host,port:5901)==secret+"-other-port" else { exit(1) }
            case "delete":
                try transport.remove(host:host,port:5900)
                try transport.remove(host:host,port:5901)
                guard try transport.read(host:host,port:5900)==nil,
                      try transport.read(host:host,port:5901)==nil else { exit(1) }
            case "legacy":
                guard try transport.read(host:host,port:5900)==nil else { exit(1) }
                do {
                    guard try transport.readLegacy(host:host,port:5900)==secret else { exit(1) }
                    print("LEGACY_AUTHORIZED")
                } catch PasswordStoreError.keychain(let status) where status==errSecAuthFailed || status==errSecInteractionNotAllowed {
                    // Denial is a valid protected-legacy outcome. The separate
                    // original synthetic owner verifies its item is unchanged.
                    print("LEGACY_PROTECTED:\(status)")
                }
            case "deny":
                _=try transport.read(host:host,port:5900)
                fputs("FAIL: untrusted caller was accepted\n",stderr);exit(1)
            default: exit(2)
            }
            print("PASS: \(action) \(build)")
            if ProcessInfo.processInfo.environment["LANTERN_LOGIN_HOLD"]=="1" {
                let connection=NSXPCConnection(serviceName:VaultV2Configuration.connectionServiceName)
                connection.remoteObjectInterface=NSXPCInterface(with:VaultV2Protocol.self)
                let certificate=Bundle.main.object(forInfoDictionaryKey:VaultConfiguration.certificateInfoKey) as! String
                let hash=Bundle.main.object(forInfoDictionaryKey:"LanternVaultServiceCDHash") as! String
                let requirement=VaultConfiguration.requirement(identifier:VaultV2Configuration.codeIdentifier,certificateSHA1:certificate)!+" and cdhash H\"\(hash)\""
                connection.setCodeSigningRequirement(requirement);connection.resume()
                let done=DispatchSemaphore(value:0)
                (connection.remoteObjectProxy as! VaultV2Protocol).read(host:host,port:5900) { _,_ in done.signal() }
                guard done.wait(timeout:.now()+3) == .success else { exit(1) }
                print("READY");fflush(stdout)
                _=readLine();connection.invalidate()
            }
        } catch {
            if action=="deny" { print("PASS: untrusted fixture rejected");return }
            fputs("FAIL: \(action): \(error.localizedDescription)\n",stderr);exit(1)
        }
    }
}
