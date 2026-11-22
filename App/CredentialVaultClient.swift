// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Security

enum CredentialVaultError: LocalizedError, Equatable {
    case unavailable, timedOut, untrustedService, invalidReply, saveUnconfirmed
    static let unconfirmedSaveExplanation="Password saving could not be confirmed. A protected copy may remain, but automatic use is disabled. Authentication dialogs remain disabled."
    var errorDescription:String? {
        switch self {
        case .unavailable: return "Saved passwords are temporarily unavailable. Authentication dialogs remain disabled."
        case .timedOut: return "The password service did not respond. Authentication dialogs remain disabled."
        case .untrustedService: return "This build could not verify its password service. No credential was shared."
        case .invalidReply: return "The password service returned an invalid response."
        case .saveUnconfirmed: return Self.unconfirmedSaveExplanation
        }
    }
}

/// Retains only fixed categories and a numeric status, never an underlying
/// error that could carry a password, endpoint, URL, userInfo or server reply.
struct CredentialSaveFailure: LocalizedError, Equatable {
    enum Stage: String {
        case intentBeforeWrite, vaultWrite, vaultReadback, valueMismatch, intentAfterWrite
    }
    enum Reason: Equatable {
        case keychain(OSStatus), vault(CredentialVaultError)
        case invalidEndpoint, invalidService, invalidStoredData, superseded, valueMismatch, unrecognized

        init(sanitizing error:Error) {
            switch error {
            case PasswordStoreError.keychain(let status): self = .keychain(status)
            case PasswordStoreError.invalidEndpoint: self = .invalidEndpoint
            case PasswordStoreError.invalidService: self = .invalidService
            case PasswordStoreError.invalidStoredData: self = .invalidStoredData
            case let known as CredentialVaultError: self = .vault(known)
            default: self = .unrecognized
            }
        }
        var diagnostic:String {
            switch self {
            case .keychain(let status): return "Keychain OSStatus \(status)"
            case .vault(.unavailable): return "service unavailable"
            case .vault(.timedOut): return "service timeout"
            case .vault(.untrustedService): return "service identity unverified"
            case .vault(.invalidReply): return "invalid service reply"
            case .vault(.saveUnconfirmed): return "service save unconfirmed"
            case .invalidEndpoint: return "invalid endpoint"
            case .invalidService: return "invalid service configuration"
            case .invalidStoredData: return "invalid stored data"
            case .superseded: return "superseded intent"
            case .valueMismatch: return "readback mismatch"
            case .unrecognized: return "unrecognized failure"
            }
        }
    }
    let stage:Stage
    let reason:Reason
    init(stage:Stage,reason:Reason) { self.stage=stage;self.reason=reason }
    init(stage:Stage,sanitizing error:Error) { self.init(stage:stage,reason:Reason(sanitizing:error)) }
    var errorDescription:String? {
        CredentialVaultError.unconfirmedSaveExplanation+" (\(stage.rawValue): \(reason.diagnostic).)"
    }
}

/// Testable transport boundary. Production calls only the narrowly scoped,
/// certificate-pinned bundled service, never a global Mach service or socket.
protocol CredentialVaultTransport {
    func read(host:String,port:UInt16)throws->String?
    func save(host:String,port:UInt16,password:String)throws
    func remove(host:String,port:UInt16)throws
}
protocol LegacyCredentialVaultReading {
    func readLegacy(host:String,port:UInt16)throws->String?
}

enum VaultServiceGeneration:Equatable {
    case legacyV1,currentV2
    var serviceName:String { self == .currentV2 ? VaultV2Configuration.connectionServiceName : VaultConfiguration.serviceName }
    var bundleName:String { self == .currentV2 ? VaultV2Configuration.bundleName : "LanternCredentialVault.xpc" }
}

private final class VaultReplyBox {
    let ready=DispatchSemaphore(value:0)
    private let lock=NSLock()
    private var value:Result<(String?,Int32),Error>?
    func finish(_ result:Result<(String?,Int32),Error>) {
        lock.lock();defer { lock.unlock() }
        guard value == nil else { return }
        value=result;ready.signal()
    }
    func result()throws->(String?,Int32) {
        lock.lock();defer { lock.unlock() }
        guard let value=value else { throw CredentialVaultError.invalidReply }
        return try value.get()
    }
}

final class XPCVaultTransport: CredentialVaultTransport, LegacyCredentialVaultReading {
    private let bundle:Bundle
    private let timeout:TimeInterval
    private let generation:VaultServiceGeneration
    init(bundle:Bundle = .main,timeout:TimeInterval = 2,generation:VaultServiceGeneration = .currentV2) {
        self.bundle=bundle;self.timeout=max(0.1,min(5,timeout))
        self.generation=generation
    }
    private func verifiedRequirement()throws->String {
        guard let certificate=bundle.object(forInfoDictionaryKey:VaultConfiguration.certificateInfoKey) as? String,
              let requirement=VaultConfiguration.requirement(identifier:VaultConfiguration.serviceName,certificateSHA1:certificate),
              let hash=bundle.object(forInfoDictionaryKey:"LanternVaultServiceCDHash") as? String,
              [40,64].contains(hash.utf8.count),hash.utf8.allSatisfy({(48...57).contains($0) || (97...102).contains($0)})
        else { throw CredentialVaultError.untrustedService }
        let helper=bundle.bundleURL.appendingPathComponent("Contents/XPCServices/"+generation.bundleName)
        let pinned=requirement+" and cdhash H\"\(hash)\""
        var check:SecRequirement?;var code:SecStaticCode?
        guard SecRequirementCreateWithString(pinned as CFString,[],&check) == errSecSuccess,
              let check=check,
              SecStaticCodeCreateWithPath(helper as CFURL,[],&code) == errSecSuccess,let code=code,
              SecStaticCodeCheckValidity(code,SecCSFlags(rawValue:kSecCSStrictValidate),check) == errSecSuccess
        else { throw CredentialVaultError.untrustedService }
        return pinned
    }
    private func call(_ request:(VaultProtocol,@escaping(String?,Int32)->Void)->Void)throws->String? {
        let requirement=try verifiedRequirement()
        let connection=NSXPCConnection(serviceName:generation.serviceName)
        connection.remoteObjectInterface=generation == .currentV2 ? NSXPCInterface(with:VaultV2Protocol.self) : NSXPCInterface(with:VaultProtocol.self)
        connection.setCodeSigningRequirement(requirement)
        let box=VaultReplyBox()
        connection.interruptionHandler={ box.finish(.failure(CredentialVaultError.unavailable)) }
        connection.invalidationHandler={ box.finish(.failure(CredentialVaultError.unavailable)) }
        connection.resume()
        defer { connection.invalidate() }
        guard let proxy=connection.remoteObjectProxyWithErrorHandler({ _ in box.finish(.failure(CredentialVaultError.unavailable)) }) as? VaultProtocol else {
            throw CredentialVaultError.unavailable
        }
        request(proxy) { secret,status in box.finish(.success((secret,status))) }
        if box.ready.wait(timeout:.now()+timeout) == .timedOut {
            box.finish(.failure(CredentialVaultError.timedOut))
        }
        let (secret,status)=try box.result()
        guard status == errSecSuccess else { throw PasswordStoreError.keychain(status) }
        return secret
    }
    func read(host:String,port:UInt16)throws->String? {
        _=try PasswordStore.account(host:host,port:port)
        return try call { $0.read(host:host,port:Int(port),reply:$1) }
    }
    func readLegacy(host:String,port:UInt16)throws->String? {
        _=try PasswordStore.account(host:host,port:port)
        guard generation == .currentV2 else { throw CredentialVaultError.unavailable }
        return try call { proxy,reply in
            guard let versioned=proxy as? VaultV2Protocol else { reply(nil,errSecUnimplemented);return }
            versioned.readLegacy(host:host,port:Int(port),reply:reply)
        }
    }
    func save(host:String,port:UInt16,password:String)throws {
        _=try PasswordStore.account(host:host,port:port)
        _=try call { proxy,reply in proxy.save(host:host,port:Int(port),password:password) { reply(nil,$0) } }
    }
    func remove(host:String,port:UInt16)throws {
        _=try PasswordStore.account(host:host,port:port)
        _=try call { proxy,reply in proxy.remove(host:host,port:Int(port)) { reply(nil,$0) } }
    }
}

/// Only read older namespaces where the OS already authorizes this code.
/// Writes and deletions always belong to the new service, never to legacy data.
final class PreviousPasswordStore:PasswordStorage {
    private let vault:LegacyCredentialVaultReading
    private let classic:PasswordStorage
    init(vault:LegacyCredentialVaultReading = XPCVaultTransport(),classic:PasswordStorage = PasswordStore()) {
        self.vault=vault;self.classic=classic
    }
    func read(host:String,port:UInt16)throws->String? {
        _=try PasswordStore.account(host:host,port:port)
        var unavailable=false
        do { if let secret=try vault.readLegacy(host:host,port:port) { return secret } } catch { unavailable=true }
        do { if let secret=try classic.read(host:host,port:port) { return secret } } catch { unavailable=true }
        if unavailable { throw CredentialVaultError.unavailable }
        return nil
    }
    func save(host:String,port:UInt16,password:String)throws { throw CredentialVaultError.unavailable }
    func remove(host:String,port:UInt16)throws { throw CredentialVaultError.unavailable }
}

/// New saved credentials are owned by the immutable service, so replacing the
/// viewer no longer replaces the code identity authorized by Keychain. Legacy
/// credentials migrate only after an already-authorized noninteractive read;
/// protected old items are never altered or bypassed.
final class PersistentPasswordStore: PasswordStorage {
    private let vault:CredentialVaultTransport
    private let legacy:PasswordStorage
    private let defaults:UserDefaults
    private let lock=NSRecursiveLock()
    /// Never held during RPC. Forget can immediately suppress use even while
    /// a different thread is blocked waiting for a vault operation.
    private static let metadataLock=NSRecursiveLock()
    private static let migratedKey="credentialVaultManagedEndpoints.v2"
    private static let forgottenKey="credentialVaultForgottenEndpoints.v1"
    private static let intentKey="credentialVaultIntentMarkers.v1"
    init(vault:CredentialVaultTransport = XPCVaultTransport(),legacy:PasswordStorage = PreviousPasswordStore(),defaults:UserDefaults = .standard) {
        self.vault=vault;self.legacy=legacy;self.defaults=defaults
    }
    private func managed(_ account:String)->Bool {
        Self.metadataLock.lock();defer { Self.metadataLock.unlock() }
        return (defaults.stringArray(forKey:Self.migratedKey) ?? []).contains(account)
    }
    private func markManaged(_ account:String) {
        Self.metadataLock.lock();defer { Self.metadataLock.unlock() }
        var entries=Set(defaults.stringArray(forKey:Self.migratedKey) ?? []);entries.insert(account)
        // Endpoint metadata only. No password, encryption/authentication key or ciphertext lives
        // in preferences, and forgetting a new credential never revives an old one.
        defaults.set(entries.sorted(),forKey:Self.migratedKey)
    }
    private func suppressed(_ account:String)->Bool {
        Self.metadataLock.lock();defer { Self.metadataLock.unlock() }
        return (defaults.stringArray(forKey:Self.forgottenKey) ?? []).contains(account)
    }
    private func setSuppressed(_ account:String,_ value:Bool) {
        Self.metadataLock.lock();defer { Self.metadataLock.unlock() }
        var entries=Set(defaults.stringArray(forKey:Self.forgottenKey) ?? [])
        if value { entries.insert(account) } else { entries.remove(account) }
        defaults.set(entries.sorted(),forKey:Self.forgottenKey)
    }
    private func intent(_ account:String)->String? {
        Self.metadataLock.lock();defer { Self.metadataLock.unlock() }
        return (defaults.dictionary(forKey:Self.intentKey) as? [String:String])?[account]
    }
    private func beginIntent(_ account:String,forget:Bool)->String {
        Self.metadataLock.lock();defer { Self.metadataLock.unlock() }
        let marker=UUID().uuidString
        var entries=defaults.dictionary(forKey:Self.intentKey) as? [String:String] ?? [:]
        entries[account]=marker;defaults.set(entries,forKey:Self.intentKey)
        setSuppressed(account,true)
        if forget { markManaged(account) }
        _=defaults.synchronize()
        return marker
    }
    private func mayRead(_ account:String,intent marker:String?)->Bool {
        Self.metadataLock.lock();defer { Self.metadataLock.unlock() }
        return !suppressed(account) && intent(account) == marker
    }
    /// Metadata only: safe on the UI thread before enqueueing a deletion. It
    /// neither waits on the RPC lock nor calls Security/Keychain APIs.
    @discardableResult
    func prepareForgetting(host:String,port:UInt16)throws->String {
        beginIntent(try PasswordStore.account(host:host,port:port),forget:true)
    }
    /// Allocate the intent before enqueueing work. An old queued write must
    /// never create a new intent after the user has already chosen Forget.
    func prepareSaving(host:String,port:UInt16)throws->String {
        beginIntent(try PasswordStore.account(host:host,port:port),forget:false)
    }
    func read(host:String,port:UInt16)throws->String? {
        lock.lock();defer { lock.unlock() }
        let account=try PasswordStore.account(host:host,port:port)
        let marker=intent(account)
        guard !suppressed(account) else { return nil }
        if let secret=try vault.read(host:host,port:port) {
            Self.metadataLock.lock();defer { Self.metadataLock.unlock() }
            guard mayRead(account,intent:marker) else { return nil }
            markManaged(account);return secret
        }
        guard mayRead(account,intent:marker) else { return nil }
        guard !managed(account),let secret=try legacy.read(host:host,port:port) else { return nil }
        guard mayRead(account,intent:marker) else { return nil }
        try vault.save(host:host,port:port,password:secret)
        guard try vault.read(host:host,port:port) == secret else { throw CredentialVaultError.invalidReply }
        Self.metadataLock.lock();defer { Self.metadataLock.unlock() }
        guard mayRead(account,intent:marker) else { return nil }
        markManaged(account)
        return secret
    }
    func save(host:String,port:UInt16,password:String)throws {
        let marker:String
        do { marker=try prepareSaving(host:host,port:port) }
        catch { throw CredentialSaveFailure(stage:.intentBeforeWrite,sanitizing:error) }
        try savePrepared(host:host,port:port,password:password,intent:marker)
    }
    func savePrepared(host:String,port:UInt16,password:String,intent marker:String)throws {
        lock.lock();defer { lock.unlock() }
        let account:String
        do { account=try PasswordStore.account(host:host,port:port) }
        catch { throw CredentialSaveFailure(stage:.intentBeforeWrite,sanitizing:error) }
        // A lost write/readback reply is not proof that nothing was stored.
        // Disable automatic use until the explicit new save is confirmed.
        guard intent(account) == marker else { throw CredentialSaveFailure(stage:.intentBeforeWrite,reason:.superseded) }
        do { try vault.save(host:host,port:port,password:password) }
        catch { throw CredentialSaveFailure(stage:.vaultWrite,sanitizing:error) }
        let readback:String?
        do { readback=try vault.read(host:host,port:port) }
        catch { throw CredentialSaveFailure(stage:.vaultReadback,sanitizing:error) }
        guard readback == password else { throw CredentialSaveFailure(stage:.valueMismatch,reason:.valueMismatch) }
        Self.metadataLock.lock();defer { Self.metadataLock.unlock() }
        guard intent(account) == marker else { throw CredentialSaveFailure(stage:.intentAfterWrite,reason:.superseded) }
        markManaged(account);setSuppressed(account,false)
    }
    func remove(host:String,port:UInt16)throws {
        let marker=try prepareForgetting(host:host,port:port)
        try removePrepared(host:host,port:port,intent:marker)
    }
    func removePrepared(host:String,port:UInt16,intent marker:String)throws {
        lock.lock();defer { lock.unlock() }
        let account=try PasswordStore.account(host:host,port:port)
        // Record Forget before RPC. Even a successful deletion with a lost
        // reply cannot resurrect an old credential on the next launch.
        guard intent(account) == marker else { return }
        try vault.remove(host:host,port:port)
    }
}
