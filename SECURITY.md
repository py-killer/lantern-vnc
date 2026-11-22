# Security policy

## Supported versions

Security fixes are developed for the latest available version. Older versions do not have a separate maintenance commitment. Version 1.2.0-preview.2, build 15, is a preview candidate, not a stable release or a general security guarantee.

## Report a vulnerability

If the repository's **Security** tab offers **Report a vulnerability**, use that private reporting route. Its availability depends on repository settings.

If private reporting is unavailable, open a public issue containing only a high-level request for a private contact route. Do not include exploit instructions, private desktop data, server addresses, credentials, or a working proof of concept in that public request. A dedicated private reporting email address is not currently published. There is no promised response or fix deadline.

Once a private route is established, useful details include the affected version, a minimal reproduction, likely impact, and whether a malicious server or local access is required. Use a disposable test setup and synthetic data.

## Connection and data boundaries

- The supplied build does not encrypt the VNC transport or establish a VPN/SSH tunnel. Use a trusted network or a separately secured connection.
- A VNC server controls what its client receives. Connect only to servers you are authorized to use; do not treat server-provided content as trusted application code.
- Device profiles save a name, host, and port locally. They do not save a VNC password.
- **Remember password** is opt-in for each host and port. It writes only after a successful connection, using the classic macOS login Keychain with synchronization disabled. Plaintext passwords are never saved in preferences or profiles, or automatically included in feedback exports. Review your own feedback notes before sharing them. The app does not claim Data Protection `WhenUnlockedThisDeviceOnly` semantics or exclusion from every backup. Unchecking or removing a profile requests deletion and disables automatic reuse even if deletion cannot be confirmed. Removing a profile still frees its slot. Unconfirmed saving disables automatic reuse; a protected copy may remain. Every credential operation forbids authentication UI, and failures do not prevent manual VNC-password entry.
- **Find…** searches only active private IPv4 physical Wi-Fi/Ethernet interfaces, on one selected TCP port. Larger subnets are limited to the local `/24` neighborhood, with at most 32 simultaneous probes. It reads an RFB greeting without authenticating or sending credentials and supports cancellation. It does not enumerate public IPv4 ranges, VPN interfaces, IPv6, Bonjour, or every port. Server discovery is not proof of server identity or authorization.
- Optional clipboard sharing transfers text between the Mac and server. Disable it when that transfer is unwanted.
- Feedback exports are saved locally and should be reviewed before sharing. GitHub issues are public unless a separate private security report is used.
- Published previews use a project self-signed publisher certificate; development builds are ad hoc signed. Apple Developer ID signing and notarization remain pending. A self-signed signature is not an Apple trust endorsement.
- Build 15 uses a separately versioned fixed v2 XPC credential helper that joins the viewer’s existing security session. The public helper passed 17 checks with synthetic default login-Keychain entries without unlocking the Keychain, enabling UI or querying owner endpoints. The old v1 helper and namespace remain preserved. Older protected entries are read only when macOS already allows access, never by changing their ACL or security settings. This fixture proof does not establish recovery of an owner’s older password.

Known product limits and connection guidance are also documented in the [FAQ](docs/wiki/FAQ.md) and [troubleshooting guide](docs/wiki/Troubleshooting.md).
