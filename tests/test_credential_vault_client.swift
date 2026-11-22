// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Security

private final class FakeVault:CredentialVaultTransport {
    var values:[String:String]=[:]
    var reads=0,saves=0,removes=0
    var unavailable=false,discardWrites=false,loseSaveReply=false,loseRemoveReply=false
    var readError:Error?,saveError:Error?
    var afterRead:(()->Void)?
    func read(host:String,port:UInt16)throws->String? {
        reads += 1;if unavailable { throw CredentialVaultError.unavailable }
        if let error=readError { throw error }
        let value=values[try PasswordStore.account(host:host,port:port)]
        afterRead?();return value
    }
    func save(host:String,port:UInt16,password:String)throws {
        saves += 1;if unavailable { throw CredentialVaultError.unavailable }
        if let error=saveError { throw error }
        if !discardWrites { values[try PasswordStore.account(host:host,port:port)]=password }
        if loseSaveReply { throw CredentialVaultError.timedOut }
    }
    func remove(host:String,port:UInt16)throws {
        removes += 1;if unavailable { throw CredentialVaultError.unavailable }
        values.removeValue(forKey:try PasswordStore.account(host:host,port:port))
        if loseRemoveReply { throw CredentialVaultError.timedOut }
    }
}
private final class FakeLegacy:PasswordStorage {
    var secret:String?,denied=false,reads=0
    func read(host:String,port:UInt16)throws->String? {
        reads += 1;if denied { throw PasswordStoreError.keychain(errSecInteractionNotAllowed) };return secret
    }
    func save(host:String,port:UInt16,password:String)throws { fatalError("Legacy store must never receive new credentials") }
    func remove(host:String,port:UInt16)throws { fatalError("Protected legacy items must remain untouched") }
}
/// Both adapters expose read counters and mutation traps. The real Previous
/// wrapper must never forward a save/remove into either older namespace.
private final class FakePreviousSource:PasswordStorage,LegacyCredentialVaultReading {
    var secret:String?,failure:Error?,onRead:(()->Void)?
    var reads=0,saves=0,removes=0
    func readLegacy(host:String,port:UInt16)throws->String? { try read(host:host,port:port) }
    func read(host:String,port:UInt16)throws->String? {
        reads += 1
        if let failure=failure { throw failure }
        onRead?();return secret
    }
    func save(host:String,port:UInt16,password:String)throws { saves += 1;secret=password }
    func remove(host:String,port:UInt16)throws { removes += 1;secret=nil }
}
@main private struct VaultClientTests {
    static var checks=0
    static func expect(_ condition:Bool,_ message:String) {
        precondition(condition,message);checks += 1
    }
    static func fails(_ block:()throws->Void) {
        do { try block();fatalError("Expected fail-closed error") } catch { checks += 1 }
    }
    static func unavailable(_ block:()throws->Void) {
        do { try block();fatalError("Expected unavailable previous credential") }
        catch {
            expect((error as? CredentialVaultError) == .unavailable,"Denied old sources expose only a generic unavailable category")
        }
    }
    @discardableResult
    static func diagnostic(_ stage:CredentialSaveFailure.Stage,_ reason:CredentialSaveFailure.Reason,
                           _ block:()throws->Void)->CredentialSaveFailure {
        do { try block();fatalError("Expected sanitized save diagnostic") }
        catch {
            guard let failure=error as? CredentialSaveFailure else { fatalError("Save failure lost its typed diagnostic") }
            expect(failure.stage == stage,"Diagnostic identifies the exact failed save step")
            expect(failure.reason == reason,"Diagnostic carries only the expected sanitized reason")
            let text=failure.localizedDescription
            expect(text.components(separatedBy:"Password saving could not be confirmed").count == 2,
                   "Unconfirmed-save explanation appears exactly once")
            expect(text.contains("automatic use is disabled") && text.contains("Authentication dialogs remain disabled"),
                   "Diagnostic preserves fail-closed automatic-use and no-prompt explanations")
            expect(text.contains(stage.rawValue),"Diagnostic includes its fixed safe stage label")
            return failure
        }
    }
    static func main()throws {
        let domain="local.lantern.vault-client.tests."+UUID().uuidString
        let defaults=UserDefaults(suiteName:domain)!;defer { defaults.removePersistentDomain(forName:domain) }
        let vault=FakeVault(),old=FakeLegacy()
        let store=PersistentPasswordStore(vault:vault,legacy:old,defaults:defaults)
        expect(try store.read(host:"fake.invalid",port:5900) == nil,"Missing credentials remain missing")
        expect(old.reads == 1 && vault.saves == 0,"Missing old credentials are not invented")
        old.secret="synthetic-migration"
        expect(try store.read(host:"fake.invalid",port:5900) == old.secret,"An authorized old read migrates")
        expect(vault.saves == 1,"Migration saves once")
        let oldReads=old.reads
        let restarted=PersistentPasswordStore(vault:vault,legacy:old,defaults:UserDefaults(suiteName:domain)!)
        expect(try restarted.read(host:"FAKE.INVALID",port:5900) == old.secret,"New client reads vault after a simulated restart")
        expect(old.reads == oldReads,"New namespace avoids old password access")
        try restarted.remove(host:"fake.invalid",port:5900)
        expect(old.secret != nil,"Old protected item was not removed")
        expect(try store.read(host:"fake.invalid",port:5900) == nil,"Forget never resurrects a legacy item")
        expect(old.reads == oldReads,"Forgotten endpoint skips legacy access")
        try store.save(host:"fake.invalid",port:5900,password:"synthetic-new")
        expect(try restarted.read(host:"fake.invalid",port:5900) == "synthetic-new","New save is independently readable")
        expect(try restarted.read(host:"fake.invalid",port:5901) == old.secret,"Different endpoint has an independent migration")
        old.denied=true
        let saves=vault.saves
        fails { _=try store.read(host:"blocked.invalid",port:5900) }
        expect(vault.saves == saves,"Denied old credential creates no replacement")
        vault.unavailable=true
        let reads=old.reads
        fails { _=try store.read(host:"unavailable.invalid",port:5900) }
        expect(old.reads == reads,"Unavailable service cannot silently downgrade")
        fails { try store.save(host:"fake.invalid",port:5900,password:"synthetic-no-write") }
        fails { try store.remove(host:"fake.invalid",port:5900) }
        vault.unavailable=false
        expect(try store.read(host:"fake.invalid",port:5900) == nil,"Unconfirmed save/forget disables automatic use")
        expect(try vault.read(host:"fake.invalid",port:5900) == "synthetic-new","Unavailable delete leaves protected state intact")
        try store.save(host:"fake.invalid",port:5900,password:"synthetic-confirmed")
        expect(try store.read(host:"fake.invalid",port:5900) == "synthetic-confirmed","Confirmed explicit save reenables automatic use")
        vault.discardWrites=true;old.denied=false
        fails { try store.save(host:"lost.invalid",port:5900,password:"synthetic-readback") }
        fails { _=try store.read(host:"lost-migration.invalid",port:5900) }
        expect(try vault.read(host:"lost.invalid",port:5900) == nil,"Unverified writes never report success")
        vault.discardWrites=false;vault.loseSaveReply=true
        fails { try store.save(host:"lost-save.invalid",port:5900,password:"synthetic-lost-reply") }
        expect(try vault.read(host:"lost-save.invalid",port:5900) != nil,"A write can take effect before a reply is lost")
        expect(try store.read(host:"lost-save.invalid",port:5900) == nil,"Unconfirmed saved data is not automatically used")
        vault.loseSaveReply=false
        try vault.save(host:"preexisting.invalid",port:5900,password:"synthetic-existing-vault")
        expect(try store.read(host:"preexisting.invalid",port:5900) == "synthetic-existing-vault","Existing vault reads are supported without migration metadata")
        try vault.remove(host:"preexisting.invalid",port:5900)
        expect(try store.read(host:"preexisting.invalid",port:5900) == nil,"Existing vault read records ownership and prevents old resurrection")
        try store.save(host:"lost-forget.invalid",port:5900,password:"synthetic-forget")
        vault.loseRemoveReply=true
        fails { try store.remove(host:"lost-forget.invalid",port:5900) }
        let afterLostReply=PersistentPasswordStore(vault:vault,legacy:old,defaults:UserDefaults(suiteName:domain)!)
        let legacyBeforeForget=old.reads
        expect(try afterLostReply.read(host:"lost-forget.invalid",port:5900) == nil,"Lost deletion acknowledgment stays forgotten after restart")
        expect(old.reads == legacyBeforeForget,"A lost deletion response never remigrates old credentials")
        vault.loseRemoveReply=false
        let staleSave=try store.prepareSaving(host:"queued.invalid",port:5900)
        let forgotten=try store.prepareForgetting(host:"queued.invalid",port:5900)
        let queuedSaves=vault.saves
        fails { try store.savePrepared(host:"queued.invalid",port:5900,password:"synthetic-stale-queued",intent:staleSave) }
        expect(vault.saves == queuedSaves,"An older queued save never writes after a newer Forget")
        expect(try afterLostReply.read(host:"queued.invalid",port:5900) == nil,"Suppression survives while queued deletion has not run")
        let newerSave=try store.prepareSaving(host:"queued.invalid",port:5900)
        let queuedRemoves=vault.removes
        try store.removePrepared(host:"queued.invalid",port:5900,intent:forgotten)
        expect(vault.removes == queuedRemoves,"An older queued deletion cannot replace a newer explicit save intent")
        try store.savePrepared(host:"queued.invalid",port:5900,password:"synthetic-new-intent",intent:newerSave)
        expect(try afterLostReply.read(host:"queued.invalid",port:5900) == "synthetic-new-intent","The latest explicit save remains usable")
        try store.removePrepared(host:"queued.invalid",port:5900,intent:forgotten)
        expect(try store.read(host:"queued.invalid",port:5900) == "synthetic-new-intent","A stale delete stays superseded after new save confirmation")
        fails { _=try store.read(host:"bad host",port:0) }
        expect(VaultConfiguration.requirement(identifier:VaultConfiguration.mainIdentifier,certificateSHA1:String(repeating:"a",count:40)) != nil,"Valid certificate pin")
        expect(VaultConfiguration.requirement(identifier:"other.app",certificateSHA1:String(repeating:"a",count:40)) == nil,"Only exact app IDs allowed")
        expect(VaultConfiguration.requirement(identifier:VaultConfiguration.mainIdentifier,certificateSHA1:"injected\" or true") == nil,"Requirement injection rejected")
        fails { _=try XPCVaultTransport(bundle:Bundle.main).read(host:"fake.invalid",port:5900) }

        let diagnosticHost="diagnostic.invalid"
        let staleDiagnostic=try store.prepareSaving(host:diagnosticHost,port:5900)
        _=try store.prepareForgetting(host:diagnosticHost,port:5900)
        let writesBeforeDiagnostic=vault.saves
        diagnostic(.intentBeforeWrite,.superseded) {
            try store.savePrepared(host:diagnosticHost,port:5900,password:"synthetic-stale-diagnostic",intent:staleDiagnostic)
        }
        expect(vault.saves == writesBeforeDiagnostic,"Diagnostic does not weaken the pre-write superseded-intent guard")
        vault.saveError=PasswordStoreError.keychain(errSecInteractionNotAllowed)
        let deniedWrite=diagnostic(.vaultWrite,.keychain(errSecInteractionNotAllowed)) {
            try store.save(host:diagnosticHost,port:5900,password:"synthetic-denied-write")
        }
        expect(deniedWrite.localizedDescription.contains("OSStatus \(errSecInteractionNotAllowed)"),"Numeric Keychain status remains actionable")
        vault.saveError=nil;vault.readError=PasswordStoreError.keychain(errSecAuthFailed)
        diagnostic(.vaultReadback,.keychain(errSecAuthFailed)) {
            try store.save(host:diagnosticHost,port:5900,password:"synthetic-denied-readback")
        }
        vault.readError=nil
        expect(try store.read(host:diagnosticHost,port:5900) == nil,"Readback failure still suppresses a write that may already exist")
        vault.discardWrites=true
        diagnostic(.valueMismatch,.valueMismatch) {
            try store.save(host:"diagnostic-mismatch.invalid",port:5900,password:"synthetic-mismatch")
        }
        vault.discardWrites=false
        vault.afterRead={ _=try! store.prepareForgetting(host:diagnosticHost,port:5900) }
        diagnostic(.intentAfterWrite,.superseded) {
            try store.save(host:diagnosticHost,port:5900,password:"synthetic-superseded-after-write")
        }
        vault.afterRead=nil
        expect(try store.read(host:diagnosticHost,port:5900) == nil,"Post-write superseded guard never clears newer Forget suppression")
        for category in [CredentialVaultError.unavailable,.timedOut,.untrustedService,.invalidReply,.saveUnconfirmed] {
            vault.saveError=category
            diagnostic(.vaultWrite,.vault(category)) {
                try store.save(host:diagnosticHost,port:5900,password:"synthetic-category")
            }
        }
        vault.saveError=nil;vault.readError=CredentialVaultError.timedOut
        diagnostic(.vaultReadback,.vault(.timedOut)) {
            try store.save(host:diagnosticHost,port:5900,password:"synthetic-readback-timeout")
        }
        vault.readError=nil
        let privateValues=["synthetic-private-password","credential-bearing.invalid","https://private.invalid/path?token=synthetic-token","synthetic-server-reply"]
        let hostile=NSError(domain:privateValues[1],code:-123,userInfo:[
            NSLocalizedDescriptionKey:privateValues.joined(separator:" "),
            NSURLErrorFailingURLStringErrorKey:privateValues[2],"password":privateValues[0],"serverReply":privateValues[3]])
        vault.saveError=hostile
        let unknownWrite=diagnostic(.vaultWrite,.unrecognized) {
            try store.save(host:diagnosticHost,port:5900,password:privateValues[0])
        }
        vault.saveError=nil;vault.readError=hostile
        let unknownRead=diagnostic(.vaultReadback,.unrecognized) {
            try store.save(host:diagnosticHost,port:5900,password:privateValues[0])
        }
        vault.readError=nil
        for failure in [unknownWrite,unknownRead] {
            let representations=[failure.localizedDescription,String(describing:failure),String(reflecting:failure)]
            expect(!representations.contains(where:{ text in privateValues.contains(where:text.contains) }),
                   "No diagnostic representation retains arbitrary descriptions, endpoint, URL, password or reply")
        }
        diagnostic(.intentBeforeWrite,.invalidEndpoint) {
            try store.save(host:"bad host",port:0,password:privateValues[0])
        }

        let previousVault=FakePreviousSource(),previousClassic=FakePreviousSource()
        let previous=PreviousPasswordStore(vault:previousVault,classic:previousClassic)
        expect(try previous.read(host:"previous-direct.invalid",port:5900) == nil,"Two missing previous sources remain missing")
        expect(previousVault.reads == 1 && previousClassic.reads == 1,"Both older sources are consulted only when needed")
        previousVault.secret="synthetic-old-vault";previousClassic.secret="synthetic-old-classic"
        let classicBeforePreferred=previousClassic.reads
        expect(try previous.read(host:"previous-direct.invalid",port:5900) == "synthetic-old-vault","An authorized v1 value has priority over classic storage")
        expect(previousClassic.reads == classicBeforePreferred,"Authorized v1 lookup never touches the classic Keychain adapter")
        previousVault.failure=PasswordStoreError.keychain(errSecAuthFailed)
        expect(try previous.read(host:"previous-direct.invalid",port:5900) == "synthetic-old-classic","Denied v1 access can fall back to an independently authorized classic read")
        previousVault.failure=nil;previousVault.secret=nil
        expect(try previous.read(host:"previous-direct.invalid",port:5900) == "synthetic-old-classic","A missing v1 value can fall back to an authorized classic value")
        previousVault.failure=hostile;previousClassic.secret=nil
        unavailable { _=try previous.read(host:"previous-direct.invalid",port:5900) }
        previousVault.failure=nil;previousClassic.failure=hostile
        unavailable { _=try previous.read(host:"previous-direct.invalid",port:5900) }
        previousVault.failure=hostile
        unavailable { _=try previous.read(host:"previous-direct.invalid",port:5900) }
        do { _=try previous.read(host:"previous-direct.invalid",port:5900);fatalError("Expected denied previous sources") }
        catch {
            let text=error.localizedDescription
            expect(!privateValues.contains(where:text.contains),"Denied migration does not expose older-source errors or credential-bearing userInfo")
        }
        previousVault.failure=nil;previousVault.secret="synthetic-v1-authorized";previousClassic.failure=hostile
        let deniedClassicReads=previousClassic.reads
        expect(try previous.read(host:"previous-direct.invalid",port:5900) == "synthetic-v1-authorized","Authorized v1 read succeeds even when classic would deny access")
        expect(previousClassic.reads == deniedClassicReads,"Successful v1 lookup cannot trigger an unrelated classic authorization attempt")
        let beforeReadOnlyVault=previousVault.secret,beforeReadOnlyClassic=previousClassic.secret
        unavailable { try previous.save(host:"previous-direct.invalid",port:5900,password:"synthetic-must-not-write-old") }
        unavailable { try previous.remove(host:"previous-direct.invalid",port:5900) }
        expect(previousVault.saves == 0 && previousVault.removes == 0 && previousClassic.saves == 0 && previousClassic.removes == 0,
               "PreviousPasswordStore never delegates a write or removal to either older namespace")
        expect(previousVault.secret == beforeReadOnlyVault && previousClassic.secret == beforeReadOnlyClassic,"Rejected old-namespace writes/removals leave both old values unchanged")
        let beforeInvalidPrevious=previousVault.reads+previousClassic.reads
        fails { _=try previous.read(host:"bad host",port:0) }
        expect(previousVault.reads+previousClassic.reads == beforeInvalidPrevious,"Invalid migration endpoints are rejected before any older-source read")

        let migrationVault=FakeVault()
        previousClassic.failure=nil
        let migration=PersistentPasswordStore(vault:migrationVault,legacy:previous,defaults:defaults)
        let migrationHost="previous-migration.invalid"
        let beforeMigratingClassic=previousClassic.reads
        expect(try migration.read(host:migrationHost,port:5900) == "synthetic-v1-authorized","An authorized previous-wrapper read migrates into the current namespace")
        expect(migrationVault.saves == 1 && previousClassic.reads == beforeMigratingClassic,"Migration writes current storage once and leaves the unneeded old adapter unread")
        let managedReads=previousVault.reads+previousClassic.reads
        migrationVault.values.removeValue(forKey:try PasswordStore.account(host:migrationHost,port:5900))
        expect(try migration.read(host:migrationHost,port:5900) == nil,"Managed endpoint does not resurrect a still-authorized older value after current storage disappears")
        expect(previousVault.reads+previousClassic.reads == managedReads && migrationVault.saves == 1,"Managed guard executes before PreviousPasswordStore and prevents remigration writes")

        let oldManagedHost="previous-v1-managed-upgrade.invalid"
        let oldManagedAccount=try PasswordStore.account(host:oldManagedHost,port:5900)
        defaults.set([oldManagedAccount],forKey:"credentialVaultManagedEndpoints.v1")
        let beforeUpgradeWrites=migrationVault.saves,beforeUpgradeReads=previousVault.reads
        expect(try migration.read(host:oldManagedHost,port:5900) == "synthetic-v1-authorized","Confirmed v1 ownership does not block an authorized first migration into the new v2 namespace")
        expect(migrationVault.saves == beforeUpgradeWrites+1 && previousVault.reads == beforeUpgradeReads+1,"First v2 migration reads authorized old data and writes only the new namespace")
        expect((defaults.stringArray(forKey:"credentialVaultManagedEndpoints.v1") ?? []).contains(oldManagedAccount) &&
               (defaults.stringArray(forKey:"credentialVaultManagedEndpoints.v2") ?? []).contains(oldManagedAccount),
               "v2 migration records new ownership without editing the old ownership marker")
        migrationVault.values.removeValue(forKey:oldManagedAccount)
        let afterUpgradeOldReads=previousVault.reads+previousClassic.reads
        expect(try migration.read(host:oldManagedHost,port:5900) == nil,"A confirmed v2-managed upgrade cannot revive old data if its v2 value later disappears")
        expect(previousVault.reads+previousClassic.reads == afterUpgradeOldReads,"Generation-scoped v2 ownership still prevents old-namespace resurrection")

        let oldForgottenHost="previous-v1-forgotten-upgrade.invalid"
        let oldForgottenAccount=try PasswordStore.account(host:oldForgottenHost,port:5900)
        defaults.set([oldManagedAccount,oldForgottenAccount],forKey:"credentialVaultManagedEndpoints.v1")
        var sharedForgotten=defaults.stringArray(forKey:"credentialVaultForgottenEndpoints.v1") ?? []
        sharedForgotten.append(oldForgottenAccount);defaults.set(sharedForgotten,forKey:"credentialVaultForgottenEndpoints.v1")
        let beforeOldForgetReads=previousVault.reads+previousClassic.reads,beforeOldForgetCurrent=migrationVault.reads
        expect(try migration.read(host:oldForgottenHost,port:5900) == nil,"A shared v1 Forget tombstone survives the backend upgrade and blocks otherwise authorized old data")
        expect(previousVault.reads+previousClassic.reads == beforeOldForgetReads && migrationVault.reads == beforeOldForgetCurrent,
               "Old-generation Forget is checked before all current and previous secret reads")
        expect(!(defaults.stringArray(forKey:"credentialVaultManagedEndpoints.v2") ?? []).contains(oldForgottenAccount),
               "An old forgotten endpoint is never marked migrated into v2")

        let suppressedHost="previous-suppressed.invalid"
        try migrationVault.save(host:suppressedHost,port:5900,password:"synthetic-current-before-forget")
        _=try migration.prepareForgetting(host:suppressedHost,port:5900)
        let suppressedOldReads=previousVault.reads+previousClassic.reads,suppressedCurrentReads=migrationVault.reads
        let suppressedRestart=PersistentPasswordStore(vault:migrationVault,legacy:previous,defaults:UserDefaults(suiteName:domain)!)
        expect(try suppressedRestart.read(host:suppressedHost,port:5900) == nil,"Restarted wrapper respects Forget before any old-namespace migration")
        expect(previousVault.reads+previousClassic.reads == suppressedOldReads && migrationVault.reads == suppressedCurrentReads,"Suppression guard prevents both current and previous secret reads before queued deletion")
        expect(migrationVault.values[try PasswordStore.account(host:suppressedHost,port:5900)] == "synthetic-current-before-forget","Immediate suppression does not mutate protected test data while deletion is pending")

        let beforeUnavailablePrevious=previousVault.reads+previousClassic.reads
        migrationVault.unavailable=true
        fails { _=try migration.read(host:"previous-current-unavailable.invalid",port:5900) }
        expect(previousVault.reads+previousClassic.reads == beforeUnavailablePrevious,"Unavailable current transport never downgrades to either older credential source")
        migrationVault.unavailable=false
        previousVault.failure=hostile;previousClassic.secret="synthetic-authorized-classic-fallback"
        expect(try migration.read(host:"previous-classic-fallback.invalid",port:5900) == "synthetic-authorized-classic-fallback","Current migration accepts only the independently authorized classic fallback after a denied v1 read")
        previousClassic.failure=hostile
        let beforeDeniedMigration=migrationVault.saves
        unavailable { _=try migration.read(host:"previous-both-denied.invalid",port:5900) }
        expect(migrationVault.saves == beforeDeniedMigration,"Denied previous sources never create a replacement in current storage")
        previousVault.failure=nil;previousClassic.failure=nil
        let raceHost="previous-forget-during-read.invalid",beforeRaceWrites=migrationVault.saves
        previousVault.onRead={ _=try! migration.prepareForgetting(host:raceHost,port:5900) }
        expect(try migration.read(host:raceHost,port:5900) == nil,"Forget during an authorized previous read rejects the late legacy value")
        previousVault.onRead=nil
        expect(migrationVault.saves == beforeRaceWrites,"Late previous read cannot write into current storage after Forget")
        expect(previousVault.saves == 0 && previousVault.removes == 0 && previousClassic.saves == 0 && previousClassic.removes == 0,
               "All previous-wrapper migration, denial and Forget cases keep older data strictly read-only")
        let metadata=defaults.persistentDomain(forName:domain) ?? [:]
        let bytes=try PropertyListSerialization.data(fromPropertyList:metadata,format:.xml,options:0)
        expect(!String(decoding:bytes,as:UTF8.self).contains("synthetic-"),"Preferences contain endpoint metadata only")
        print("PASS: \(checks) vault client migration, isolation, sanitized diagnostics and noninteractive-policy checks")
    }
}
