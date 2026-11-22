// SPDX-License-Identifier: GPL-2.0-or-later
// Executed only inside test-owned app fixtures with an ephemeral test Keychain.
import Foundation

@main struct VaultHarness {
    static func main() {
        let marker = "LANTERN_VAULT_BUILD_MARKER"
        guard CommandLine.arguments.count == 2 else { exit(2) }
        let mode = CommandLine.arguments[1]
        let transport = XPCVaultTransport(timeout: 3,generation:.legacyV1)
        let host = "owned-vault-fixture.invalid"
        let secret = "synthetic-vault-🐯-credential"
        do {
            if mode == "deny" {
                _ = try transport.read(host: host, port: 5900)
                fputs("FAIL: untrusted fixture reached the credential service.\n", stderr); exit(1)
            }
            switch mode {
            case "write":
                try transport.save(host: host, port: 5900, password: secret)
                guard try transport.read(host: host.uppercased(), port: 5900) == secret else { exit(1) }
            case "read":
                guard try transport.read(host: host, port: 5900) == secret else { exit(1) }
            case "update":
                try transport.save(host: host, port: 5900, password: secret)
                try transport.save(host: host, port: 5901, password: secret + "-other-port")
                guard try transport.read(host: host, port: 5900) == secret,
                      try transport.read(host: host, port: 5901) == secret + "-other-port",
                      try transport.read(host: "other-owned-fixture.invalid", port: 5900) == nil else { exit(1) }
            case "delete":
                try transport.remove(host: host, port: 5900)
                try transport.remove(host: host, port: 5901)
                try transport.remove(host: host, port: 5901)
                guard try transport.read(host: host, port: 5900) == nil,
                      try transport.read(host: host, port: 5901) == nil else { exit(1) }
            default: exit(2)
            }
            print("PASS: \(mode) \(marker)")
        } catch {
            if mode == "deny" { print("PASS: rejected untrusted fixture \(marker)"); return }
            // Framework/store errors contain no endpoint, query, or credential.
            fputs("FAIL: \(mode) \(marker): \(error.localizedDescription)\n", stderr); exit(1)
        }
    }
}
