# Credential service

The current unprivileged, bundled XPC service owns new credentials in the classic
macOS login Keychain under `local.lantern.vnc.password.vault.v2`. Every Keychain
operation is noninteractive. The main app and service authenticate each other
with certificate-and-identifier requirements; the app also pins the service's
code hash. The service has no enumeration, arbitrary-service, ACL-editing, or
authentication-dialog interface. Generation2 sets `JoinExistingSession=true`
so its default Keychain access occurs in the main app's existing login security
session. It never unlocks that Keychain. If access is unavailable, it fails with
authentication UI disabled.

Generation1 omitted that session setting. Its private cache, original three
source inputs, and `v1/frozen-manifest.json` are retained unchanged because it
may own a protected item. Generation2 uses a separate namespace and offers only
an explicit read-only `readLegacy` migration operation. The main app's managed
and suppressed-intent checks govern whether migration is appropriate. A normal
v2 read never falls back to an old v1 item after a v2 deletion.

The service must remain **byte-for-byte unchanged across main-app updates**.
Its source inputs and released file hashes are recorded in
`frozen-manifest.json`. Build scripts validate the private cached bundle and
refuse to replace it if the source, certificate, or bundle differs. Do not
delete that cache or regenerate its identity to fix a credential error. A
service change requires a reviewed migration while the old service remains
authorized. Inaccessible credentials created by old ad hoc main-app builds
cannot be recovered by this architecture.

## Building with your own identity

The private signing tool is a build-time dependency, not part of the runtime
app. Obtain and verify `rcodesign0.29.0` from the
[official release](https://github.com/indygreg/apple-platform-rs/releases/tag/apple-codesign/0.29.0).
The arm64 archive SHA-256 is
`d1a532150adaf90048260d76359261aa716abafc45c53c5dc18845029184334a`.
Do not use an unverified executable or a publicly shared private signing key.

Generate one private, long-lived project identity, with the verified tool path
in `RCODESIGN`:

```sh
RCODESIGN=/absolute/path/to/rcodesign \
  python3 scripts/setup-local-signing.py "$PWD/.git/codex-signing"
```

This retains an encrypted PKCS12 identity and a generated wrapping-password
file with mode0600 inside a mode0700 directory. It makes no Keychain, trust,
or search-list changes and asks for no credential. It never overwrites an
existing identity. The generated `release-config.json` contains private file
paths and public certificate metadata, not the password or private key.
Securely back up the complete private directory. Never commit, package, or
publish it. `PublisherCertificate.pem` contains only the public certificate.

The normal build and packaging scripts find `.git/codex-signing/release-config.json`
automatically. For a different private directory, set `LANTERN_SIGNING_CONFIG`
to its configuration file. Both call `finalize-app-signature.py` after adding
resources, preserving the nested service. Without private signing configuration,
the source checkout produces an ad hoc development build with manual VNC access
and no trusted persistent-credential service; do not distribute it as a publisher
release. Forks need their own signing identity and credential service.

Build the service once with `scripts/build-credential-vault.sh`, passing the
certificate SHA-1, encrypted P12, password file and private cache directory
from that configuration, plus generation `2` (the default). Generation1 cache
validation requires an explicit final `1`. Reuse the exact cached bundle in
each release. The v2 connection name is
`local.lantern.vnc.credential-vault-v2` and its bundle is
`LanternCredentialVaultV2.xpc`; its code-signing identifier remains
`local.lantern.vnc.credential-vault` with the same publisher certificate. The
signing wrapper verifies that distinction with Apple's strict requirements.
`scripts/sign-with-local-identity.sh` signs a main app with
`rcodesign --exclude '**'` so nested service bytes remain unchanged. It then
uses Apple's strict signature verification with an explicit certificate
requirement. Security evaluation may require execution outside a restricted
build sandbox; a failed verification is not a passing release result.

This is a self-signed project identity. It supplies cryptographic continuity,
not Apple Developer ID, notarization, or a Gatekeeper trust exception. A
different builder's identity cannot impersonate the published project or gain
access to its protected credentials.

## Isolated verification

```sh
RCODESIGN=/absolute/path/to/verified/rcodesign tests/run-vault-tests.sh
```

The test builds separate signed app fixtures and a `VAULT_HARNESS` service
against a newly generated private Keychain. It verifies updates and service
restarts, credential isolation/deletion, app movement, peer rejection and
helper-hash pinning. Generated fixture passwords and private keys are not
printed. Only owned test processes and items are cleaned up.

The shipping service is compiled without `VAULT_HARNESS`. Its bundle and
binary must contain no test Keychain, unlock, audit, or password-file hooks.
The public service links only Apple system frameworks and libraries.

The session/deployment regression is separate from the private-file fixture:

```sh
tests/run-vault-login-tests.sh /private/release-config.json /private/credential-vault-v2
```

It exercises the exact PUBLICv2 bundle against newly generated UUID endpoints
in the default login Keychain, without unlock calls or test hooks in that
bundle. It checks shared security sessions, save/read/update/delete across main
and helper restarts, and peer rejection. Only known synthetic values are used;
the runner removes its items and unregisters/removes its fixture apps. A
separate synthetic legacy owner verifies read-only migration without querying
any existing user endpoint.
