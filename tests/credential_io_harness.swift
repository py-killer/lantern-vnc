// SPDX-License-Identifier: GPL-2.0-or-later
// Real offscreen controller and PersistentPasswordStore, synthetic in-memory
// vault, isolated defaults, and an owned loopback VNC server only.
import AppKit
import MetalKit
import Foundation

private final class CredentialGate {
    private let lock=NSLock(),release=DispatchSemaphore(value:0)
    private var entered=false
    var hasEntered:Bool { lock.lock();defer {lock.unlock()};return entered }
    func wait() {
        lock.lock();entered=true;lock.unlock()
        precondition(release.wait(timeout:.now()+15) == .success,"Owned credential fixture gate expired")
    }
    func open() { release.signal() }
}

private final class EmptyLegacyCredentials: PasswordStorage {
    func read(host:String,port:UInt16)throws->String? { nil }
    func save(host:String,port:UInt16,password:String)throws { fatalError("No legacy writes in fixture") }
    func remove(host:String,port:UInt16)throws { fatalError("No legacy removals in fixture") }
}

private final class DelayedVault: CredentialVaultTransport {
    private let lock=NSLock()
    private var values:[String:String]=[:],gates:[String:CredentialGate]=[:]
    private var calls:[String:Int]=[:]
    private var mainThreadCall=false
    private var ambiguousNextSave=false
    private func key(_ host:String,_ port:UInt16)->String { WorkspaceComputer.key(host:host,port:port) }
    func seed(_ host:String,_ port:UInt16,_ value:String) { lock.lock();values[key(host,port)]=value;lock.unlock() }
    func value(_ host:String,_ port:UInt16)->String? { lock.lock();defer {lock.unlock()};return values[key(host,port)] }
    func pauseNext(_ operation:String)->CredentialGate {
        lock.lock();defer {lock.unlock()}
        let gate=CredentialGate();gates[operation]=gate;return gate
    }
    func failNextSaveAfterWrite() { lock.lock();ambiguousNextSave=true;lock.unlock() }
    var allCallsOffMain:Bool { lock.lock();defer {lock.unlock()};return !mainThreadCall }
    func callCount(_ operation:String)->Int { lock.lock();defer {lock.unlock()};return calls[operation,default:0] }
    private func begin(_ operation:String)->CredentialGate? {
        lock.lock();defer {lock.unlock()}
        mainThreadCall = mainThreadCall || Thread.isMainThread
        calls[operation,default:0] += 1
        return gates.removeValue(forKey:operation)
    }
    func read(host:String,port:UInt16)throws->String? {
        let gate=begin("read"),snapshot=value(host,port)
        gate?.wait();return snapshot
    }
    func save(host:String,port:UInt16,password:String)throws {
        begin("save")?.wait()
        lock.lock();values[key(host,port)]=password
        let ambiguous=ambiguousNextSave;ambiguousNextSave=false;lock.unlock()
        if ambiguous { throw CredentialVaultError.timedOut }
    }
    func remove(host:String,port:UInt16)throws {
        begin("remove")?.wait()
        lock.lock();values.removeValue(forKey:key(host,port));lock.unlock()
    }
}

@main
struct CredentialIOHarness {
    private static var checks=0
    private static func expect(_ value:@autoclosure()->Bool,_ label:String) {
        checks += 1;guard value() else { fatalError("Credential IO harness: "+label) }
    }
    private static func settle(_ seconds:TimeInterval=0.02) { RunLoop.current.run(until:Date(timeIntervalSinceNow:seconds)) }
    private static func wait(_ label:String,timeout:TimeInterval=8,until ready:()->Bool) {
        let deadline=Date(timeIntervalSinceNow:timeout)
        while !ready() && Date() < deadline { settle() }
        expect(ready(),label)
    }
    private static func views(_ root:NSView)->[NSView] { [root]+root.subviews.flatMap(views) }
    private static func find<T:NSView>(_ id:String,in controller:ViewerController,as type:T.Type)->T {
        guard let root=controller.window?.contentView,
              let view=views(root).first(where:{$0.identifier?.rawValue == id}) as? T else { fatalError("Missing owned credential control") }
        return view
    }
    private static func change(_ field:NSTextField,to value:String,controller:ViewerController,finish:Bool=false) {
        field.stringValue=value
        controller.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:field))
        if finish { controller.controlTextDidEndEditing(Notification(name:NSControl.textDidEndEditingNotification,object:field)) }
    }
    private static func remember(_ value:NSControl.StateValue,in controller:ViewerController) {
        let control:NSButton=find("rememberPassword",in:controller,as:NSButton.self)
        control.state=value;expect(control.sendAction(control.action,to:control.target),"remember action reaches the owned controller")
    }
    private static func drain(_ controller:ViewerController) {
        wait("all owned credential replies complete") { controller.testingPendingCredentialOperations == 0 }
    }
    private static func freshRead(_ defaults:UserDefaults,vault:DelayedVault,host:String,port:UInt16)->String? {
        let store=PersistentPasswordStore(vault:vault,legacy:EmptyLegacyCredentials(),defaults:defaults)
        var reply:Result<String?,Error>?
        DispatchQueue(label:"owned.credential-fresh-read").async {
            let result=Result { try store.read(host:host,port:port) }
            DispatchQueue.main.async { reply=result }
        }
        wait("new-store fixture read completes without waiting for unrelated queued RPC",timeout:1) { reply != nil }
        do { return try reply!.get() } catch { fatalError("Owned fresh-store read failed") }
    }
    private static func heartbeat(_ gate:CredentialGate,controller:ViewerController) {
        wait("owned credential operation is held off main") { gate.hasEntered }
        var ran=false;DispatchQueue.main.async { ran=true }
        wait("main queue remains responsive while credential service is held",timeout:0.5) { ran }
        expect(controller.window?.attachedSheet == nil,"blocked credential service never creates an authorization sheet")
    }
    private static func close(_ controller:ViewerController) {
        controller.stop();drain(controller)
        controller.window?.delegate=nil;controller.window?.orderOut(nil);controller.window?.close()
    }
    private static func make(_ defaults:UserDefaults,_ vault:DelayedVault)throws->ViewerController {
        let store=PersistentPasswordStore(vault:vault,legacy:EmptyLegacyCredentials(),defaults:defaults)
        let controller=try ViewerController(showWindow:false,preferences:defaults,passwordStore:store)
        controller.window?.ignoresMouseEvents=true
        controller.window?.setFrameOrigin(NSPoint(x:-10000,y:-10000))
        expect(controller.testingAsynchronousCredentials,"PersistentPasswordStore automatically uses serial background IO")
        return controller
    }
    private static func configured(_ domain:String,host:String,port:UInt16)->UserDefaults {
        let defaults=UserDefaults(suiteName:domain)!
        defaults.removePersistentDomain(forName:domain)
        defaults.set(host,forKey:"server");defaults.set(String(port),forKey:"port")
        return defaults
    }

    static func main() throws {
        guard CommandLine.arguments.count == 3,let vncPort=UInt16(CommandLine.arguments[1]) else { exit(2) }
        guard MTLCreateSystemDefaultDevice() != nil,!NSScreen.screens.isEmpty else {
            fputs("UNAVAILABLE: credential UI fixtures require Metal/WindowServer (exit77).\n",stderr);exit(77)
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        let productionBefore=UserDefaults.standard.persistentDomain(forName:"local.lantern.vnc")
        var domains:[String]=[]
        func preferences(_ name:String,host:String="read-a.invalid")->UserDefaults {
            let domain="LanternVNC.CredentialIO."+UUID().uuidString+"."+name;domains.append(domain)
            return configured(domain,host:host,port:vncPort)
        }
        defer { for domain in domains { UserDefaults(suiteName:domain)?.removePersistentDomain(forName:domain) } }

        let vault=DelayedVault(),defaults=preferences("read")
        vault.seed("read-a.invalid",vncPort,"owned-saved-A")
        let readGate=vault.pauseNext("read"),controller=try make(defaults,vault)
        heartbeat(readGate,controller:controller)
        let password:NSSecureTextField=find("serverPassword",in:controller,as:NSSecureTextField.self)
        let host:NSTextField=find("serverHost",in:controller,as:NSTextField.self)
        let rememberControl:NSButton=find("rememberPassword",in:controller,as:NSButton.self)
        change(password,to:"owned-manual-value",controller:controller)
        readGate.open();drain(controller)
        expect(password.stringValue == "owned-manual-value" && rememberControl.state == .off,
               "late startup read cannot replace a typed password or re-enable Remember")
        vault.seed("read-b.invalid",vncPort,"owned-saved-B");vault.seed("read-c.invalid",vncPort,"owned-saved-C")
        let endpointGate=vault.pauseNext("read")
        change(host,to:"read-b.invalid",controller:controller,finish:true)
        heartbeat(endpointGate,controller:controller)
        change(host,to:"read-c.invalid",controller:controller,finish:true)
        endpointGate.open();drain(controller)
        expect(password.stringValue == "owned-saved-C" && rememberControl.state == .on,
               "delayed endpoint B never leaks into endpoint C")
        let forgetGate=vault.pauseNext("read")
        change(host,to:"read-a.invalid",controller:controller,finish:true)
        heartbeat(forgetGate,controller:controller)
        remember(.off,in:controller);forgetGate.open();drain(controller)
        expect(password.stringValue.isEmpty && rememberControl.state == .off && vault.value("read-a.invalid",vncPort) == nil,
               "Forget suppresses a pending saved read and serially removes its old value")
        expect(vault.allCallsOffMain,"all delayed read/forget calls ran outside the main thread")
        close(controller)

        let deletionVault=DelayedVault(),deletionDefaults=preferences("delete",host:"127.0.0.1")
        deletionVault.seed("127.0.0.1",vncPort,"mock-password")
        let deleteGate=deletionVault.pauseNext("read"),deleted=try make(deletionDefaults,deletionVault)
        let deletedProfile=DeviceStore(defaults:deletionDefaults).devices[0]
        heartbeat(deleteGate,controller:deleted);deleted.testingStartSavedPreviews()
        deleted.testingRemoveComputer(id:deletedProfile.id)
        expect(DeviceStore(defaults:deletionDefaults).devices.isEmpty,"profile deletion is immediate while credential IO is delayed")
        deleteGate.open();drain(deleted);settle(0.15)
        expect(deleted.testingComputerCount == 0 && deleted.testingCurrentSession == nil,
               "deleted-profile pending startup read cannot launch or recreate its worker")
        expect(deletionVault.value("127.0.0.1",vncPort) == nil,"queued profile Forget follows delayed reads")
        close(deleted)

        let cancelVault=DelayedVault(),cancelDefaults=preferences("cancel",host:"127.0.0.1")
        cancelVault.seed("127.0.0.1",vncPort,"mock-password")
        let canceled=try make(cancelDefaults,cancelVault);drain(canceled)
        let cancelProfile=DeviceStore(defaults:cancelDefaults).devices[0],cancelGate=cancelVault.pauseNext("read")
        canceled.testingSelectComputer(id:cancelProfile.id);heartbeat(cancelGate,controller:canceled)
        let cancelPassword:NSSecureTextField=find("serverPassword",in:canceled,as:NSSecureTextField.self)
        change(cancelPassword,to:"owned-manual-cancel",controller:canceled)
        cancelGate.open();drain(canceled);settle(0.15)
        expect(canceled.testingCurrentSession == nil && canceled.testingComputerCount == 0 && cancelPassword.stringValue == "owned-manual-cancel",
               "typing cancels delayed automatic connection without replacing the typed password")
        let stopGate=cancelVault.pauseNext("read")
        canceled.testingSelectComputer(id:cancelProfile.id);heartbeat(stopGate,controller:canceled)
        canceled.stop();stopGate.open();drain(canceled);settle(0.15)
        expect(canceled.testingCurrentSession == nil && canceled.testingComputerCount == 0,"Stop invalidates delayed automatic connections")
        close(canceled)

        // Hold an unrelated RPC so the authenticated Save is queued but has
        // not begun. Deleting its profile must invalidate Save immediately;
        // hold the later deletion too, proving stale Save never wrote at all.
        let queuedVault=DelayedVault(),queuedDefaults=preferences("queued-save-forget",host:"127.0.0.1")
        let queued=try make(queuedDefaults,queuedVault);drain(queued)
        let queuedProfile=DeviceStore(defaults:queuedDefaults).devices[0]
        let queuedHost:NSTextField=find("serverHost",in:queued,as:NSTextField.self)
        let queuedPassword:NSSecureTextField=find("serverPassword",in:queued,as:NSSecureTextField.self)
        let queuedConnect:NSButton=find("connectButton",in:queued,as:NSButton.self)
        let queuedHint:NSTextField=find("passwordHint",in:queued,as:NSTextField.self)
        let unrelatedRead=queuedVault.pauseNext("read")
        change(queuedHost,to:"blocked-owned.invalid",controller:queued,finish:true);heartbeat(unrelatedRead,controller:queued)
        change(queuedHost,to:"127.0.0.1",controller:queued,finish:true)
        change(queuedPassword,to:"mock-password",controller:queued);remember(.on,in:queued);queued.toggleConnection()
        wait("authenticated Save is queued behind an unrelated held RPC") {
            queuedConnect.title == "Disconnect" && queuedHint.stringValue == "Saving password securely…"
        }
        expect(queuedVault.callCount("save") == 0,"queued authenticated Save has not reached the vault")
        let queuedDelete=queuedVault.pauseNext("remove")
        queued.testingRemoveComputer(id:queuedProfile.id)
        unrelatedRead.open();heartbeat(queuedDelete,controller:queued)
        expect(queuedVault.callCount("save") == 0 && queuedVault.value("127.0.0.1",vncPort) == nil,
               "newer Forget skips the older queued Save before any vault mutation, while deletion is still blocked")
        expect(freshRead(queuedDefaults,vault:queuedVault,host:"127.0.0.1",port:vncPort) == nil,
               "queued stale Save cannot revive automatic use before queued deletion completes")
        queuedDelete.open();drain(queued);close(queued)

        // Reverse the order. Old Forget is queued before a new authenticated
        // Save, so it must not delete or replace the newer Save's intent.
        let newerVault=DelayedVault(),newerDefaults=preferences("queued-forget-save",host:"127.0.0.1")
        let newer=try make(newerDefaults,newerVault);drain(newer)
        newerVault.seed("127.0.0.1",vncPort,"owned-old-value")
        let newerHost:NSTextField=find("serverHost",in:newer,as:NSTextField.self)
        let newerPassword:NSSecureTextField=find("serverPassword",in:newer,as:NSSecureTextField.self)
        let newerConnect:NSButton=find("connectButton",in:newer,as:NSButton.self)
        let newerHint:NSTextField=find("passwordHint",in:newer,as:NSTextField.self)
        let oldRead=newerVault.pauseNext("read")
        change(newerHost,to:"blocked-owned.invalid",controller:newer,finish:true);heartbeat(oldRead,controller:newer)
        change(newerHost,to:"127.0.0.1",controller:newer,finish:true);remember(.off,in:newer)
        change(newerPassword,to:"mock-password",controller:newer);remember(.on,in:newer)
        let newerSave=newerVault.pauseNext("save");newer.toggleConnection()
        wait("new authenticated Save intent is prepared after queued Forget") {
            newerConnect.title == "Disconnect" && newerHint.stringValue == "Saving password securely…"
        }
        oldRead.open();heartbeat(newerSave,controller:newer)
        expect(newerVault.callCount("remove") == 0 && newerVault.value("127.0.0.1",vncPort) == "owned-old-value",
               "older queued Forget skips vault deletion and cannot overwrite the newer queued Save intent")
        expect(freshRead(newerDefaults,vault:newerVault,host:"127.0.0.1",port:vncPort) == nil,
               "new Save remains suppressed until its own write is confirmed")
        newerSave.open();drain(newer)
        expect(newerHint.stringValue == "Password saved securely on this Mac." && newerVault.callCount("remove") == 0,
               "newer Save completes without an older queued deletion clobbering it")
        expect(freshRead(newerDefaults,vault:newerVault,host:"127.0.0.1",port:vncPort) == "mock-password",
               "new store can use only the independently confirmed newest Save")
        close(newer)

        let saveVault=DelayedVault(),saveDefaults=preferences("save",host:"127.0.0.1")
        let profiles=DeviceStore(defaults:saveDefaults)
        let savedProfile=profiles.save(name:"Owned restart alias",host:"127.0.0.1",port:vncPort)!
        _=ConnectionPreferencesStore(defaults:saveDefaults).save(host:"127.0.0.1",port:vncPort,zoomMode:.scale(1.5),qualityIndex:1)
        let saving=try make(saveDefaults,saveVault);drain(saving)
        let savePassword:NSSecureTextField=find("serverPassword",in:saving,as:NSSecureTextField.self)
        let saveConnect:NSButton=find("connectButton",in:saving,as:NSButton.self)
        let saveHint:NSTextField=find("passwordHint",in:saving,as:NSTextField.self)
        change(savePassword,to:"mock-password",controller:saving);remember(.on,in:saving)
        let saveGate=saveVault.pauseNext("save");saving.toggleConnection()
        wait("owned VNC authentication finishes before delayed storage") { saveConnect.title == "Disconnect" && saveGate.hasEntered }
        let saveRemember:NSButton=find("rememberPassword",in:saving,as:NSButton.self)
        expect(!saveRemember.isEnabled && saveRemember.state == .on && !savePassword.isEnabled,"connected pending-save UI preserves its valid Remember intent while disabling late changes")
        heartbeat(saveGate,controller:saving);remember(.off,in:saving)
        let beforeQueuedForget=PersistentPasswordStore(vault:saveVault,legacy:EmptyLegacyCredentials(),defaults:saveDefaults)
        var queuedForgetReadDone=false,queuedForgetSuppressed=false
        DispatchQueue(label:"owned.credential-restart-before-forget").async {
            let result=Result { try beforeQueuedForget.read(host:"127.0.0.1",port:vncPort) }
            DispatchQueue.main.async {
                if case .success(nil)=result { queuedForgetSuppressed=true }
                queuedForgetReadDone=true
            }
        }
        wait("new store cannot auto-use a credential before queued Forget RPC starts",timeout:0.5) { queuedForgetReadDone }
        expect(queuedForgetSuppressed && saveGate.hasEntered,"Forget tombstone survives a new store even while the prior save is blocked")
        saveGate.open();drain(saving)
        expect(saveRemember.state == .off && saveVault.value("127.0.0.1",vncPort) == nil && !saveHint.stringValue.contains("Password saved securely"),
               "Forget during in-flight save runs afterward and a late success cannot re-enable Remember")
        saving.toggleConnection();wait("owned forgotten connection stops") { saveConnect.title == "Connect" };drain(saving)
        change(savePassword,to:"mock-password",controller:saving);remember(.on,in:saving);saving.toggleConnection()
        wait("explicit authenticated save is confirmed asynchronously") { saveConnect.title == "Disconnect" && saveHint.stringValue == "Password saved securely on this Mac." }
        expect(saveVault.value("127.0.0.1",vncPort) == "mock-password","only authenticated remembered fixture is persisted")
        close(saving)

        // New store, new controller, and preferences restored afresh. Exercise
        // the exact startup path rather than merely loading a password field.
        let restartDefaults=UserDefaults(suiteName:domains.last!)!,restarted=try make(restartDefaults,saveVault)
        restarted.testingStartSavedPreviews()
        let restartConnect:NSButton=find("connectButton",in:restarted,as:NSButton.self)
        wait("brand-new controller automatically authenticates from the saved fixture") {
            restartConnect.title == "Disconnect" && restarted.testingCurrentSession != nil && restarted.testingDesktop.framesReceived > 0
        }
        drain(restarted)
        let restartQuality:NSPopUpButton=find("pictureQuality",in:restarted,as:NSPopUpButton.self)
        let restartRemember:NSButton=find("rememberPassword",in:restarted,as:NSButton.self)
        let restartPassword:NSSecureTextField=find("serverPassword",in:restarted,as:NSSecureTextField.self)
        expect(!restartRemember.isEnabled && restartRemember.state == .on && restartPassword.stringValue.isEmpty,"saved startup renders Remember ON, disables late opt-in, and clears its secure field")
        expect(DeviceStore(defaults:restartDefaults).devices.first?.name == "Owned restart alias" && restartQuality.indexOfSelectedItem == 1 && restarted.testingDesktop.zoomMode == .scale(1.5),
               "restart auto-connect retains the saved alias, zoom and quality")
        expect(restarted.testingComputerSession(id:savedProfile.id) === restarted.testingCurrentSession,
               "startup selects the retained profile worker without a duplicate session")
        close(restarted)

        let isolationVault=DelayedVault(),isolationDefaults=preferences("save-isolation",host:"127.0.0.1")
        let isolationProfiles=DeviceStore(defaults:isolationDefaults)
        let otherProfile=isolationProfiles.save(name:"Other owned endpoint",host:"localhost",port:vncPort)!
        let isolation=try make(isolationDefaults,isolationVault);drain(isolation)
        let isolationPassword:NSSecureTextField=find("serverPassword",in:isolation,as:NSSecureTextField.self)
        let isolationConnect:NSButton=find("connectButton",in:isolation,as:NSButton.self)
        let isolationRemember:NSButton=find("rememberPassword",in:isolation,as:NSButton.self)
        let isolationHint:NSTextField=find("passwordHint",in:isolation,as:NSTextField.self)
        change(isolationPassword,to:"mock-password",controller:isolation);remember(.on,in:isolation)
        let isolationGate=isolationVault.pauseNext("save");isolationVault.failNextSaveAfterWrite();isolation.toggleConnection()
        wait("owned save can remain pending after authenticated connection") { isolationConnect.title == "Disconnect" && isolationGate.hasEntered }
        isolation.testingSelectComputer(id:otherProfile.id)
        change(isolationPassword,to:"owned-other-manual",controller:isolation);remember(.on,in:isolation)
        let otherHint=isolationHint.stringValue
        isolationGate.open();drain(isolation)
        expect(isolationPassword.stringValue == "owned-other-manual" && isolationRemember.state == .on && isolationHint.stringValue == otherHint,
               "late endpoint A save failure cannot overwrite endpoint B's typed password, Remember choice or notice")
        expect(isolation.testingComputerCount == 1 && isolation.testingCurrentSession == nil,
               "endpoint B stays disconnected while the original saved A session is retained")
        isolation.testingSelectComputer(id:DeviceStore(defaults:isolationDefaults).devices.first(where:{$0.host == "127.0.0.1"})!.id)
        expect(isolation.testingCurrentSession != nil && isolationPassword.stringValue.isEmpty && isolationRemember.state == .off && !isolationRemember.isEnabled,
               "promoting retained A shows its failed-save Remember OFF and clears B's field without retaining plaintext")
        isolationVault.seed("localhost",vncPort,"mock-password")
        isolation.testingSelectComputer(id:otherProfile.id)
        wait("owned saved B authenticates independently and renders Remember ON") {
            isolationConnect.title == "Disconnect" && isolationRemember.state == .on && isolation.testingPendingCredentialOperations == 0
        }
        isolation.testingSelectComputer(id:DeviceStore(defaults:isolationDefaults).devices.first(where:{$0.host == "127.0.0.1"})!.id)
        expect(isolationRemember.state == .off,"promoting failed-save A cannot inherit successful B's Remember ON")
        isolation.testingSelectComputer(id:otherProfile.id)
        expect(isolationRemember.state == .on && !isolationRemember.isEnabled,
               "returning to live B restores its own confirmed Remember ON after viewing failed-save A")
        close(isolation)

        let deletedSaveVault=DelayedVault(),deletedSaveDefaults=preferences("delete-save",host:"127.0.0.1")
        let deletedSave=try make(deletedSaveDefaults,deletedSaveVault);drain(deletedSave)
        let deletedSaveProfile=DeviceStore(defaults:deletedSaveDefaults).devices[0]
        let deletedSavePassword:NSSecureTextField=find("serverPassword",in:deletedSave,as:NSSecureTextField.self)
        let deletedSaveConnect:NSButton=find("connectButton",in:deletedSave,as:NSButton.self)
        change(deletedSavePassword,to:"mock-password",controller:deletedSave);remember(.on,in:deletedSave)
        let deletedSaveGate=deletedSaveVault.pauseNext("save");deletedSave.toggleConnection()
        wait("owned profile save is in flight before deletion") { deletedSaveConnect.title == "Disconnect" && deletedSaveGate.hasEntered }
        deletedSave.testingRemoveComputer(id:deletedSaveProfile.id)
        expect(DeviceStore(defaults:deletedSaveDefaults).devices.isEmpty && deletedSave.testingComputerCount == 0,
               "profile and worker disappear immediately even while their authenticated save is pending")
        deletedSaveGate.open();drain(deletedSave);settle(0.15)
        let deletedSaveRemember:NSButton=find("rememberPassword",in:deletedSave,as:NSButton.self)
        expect(deletedSaveVault.value("127.0.0.1",vncPort) == nil && deletedSavePassword.stringValue.isEmpty && deletedSaveRemember.state == .off,
               "profile Forget follows in-flight save; late success cannot restore its secret or Remember state")
        expect(DeviceStore(defaults:deletedSaveDefaults).devices.isEmpty && deletedSave.testingCurrentSession == nil,
               "late saved/disconnected callbacks cannot recreate a deleted profile or session")
        close(deletedSave)

        let ambiguousVault=DelayedVault(),ambiguousDefaults=preferences("ambiguous",host:"127.0.0.1")
        let ambiguous=try make(ambiguousDefaults,ambiguousVault);drain(ambiguous)
        let ambiguousPassword:NSSecureTextField=find("serverPassword",in:ambiguous,as:NSSecureTextField.self)
        let ambiguousRemember:NSButton=find("rememberPassword",in:ambiguous,as:NSButton.self)
        let ambiguousConnect:NSButton=find("connectButton",in:ambiguous,as:NSButton.self)
        let ambiguousHint:NSTextField=find("passwordHint",in:ambiguous,as:NSTextField.self)
        change(ambiguousPassword,to:"mock-password",controller:ambiguous);remember(.on,in:ambiguous)
        ambiguousVault.failNextSaveAfterWrite();ambiguous.toggleConnection()
        wait("ambiguous saved-write response stays inline") { ambiguousConnect.title == "Disconnect" && ambiguousRemember.state == .off && ambiguous.testingPendingCredentialOperations == 0 }
        expect(ambiguousVault.value("127.0.0.1",vncPort) != nil && ambiguousHint.stringValue.lowercased().contains("password saving could not be confirmed") && !ambiguousHint.stringValue.contains("was not saved"),
               "a lost response is never falsely described as proof that no protected value was saved")
        ambiguous.toggleConnection();wait("ambiguous connection stops") { ambiguousConnect.title == "Connect" };drain(ambiguous)
        expect(ambiguousPassword.stringValue.isEmpty && ambiguousRemember.state == .off,"unconfirmed save cannot be reused automatically after disconnect")
        close(ambiguous)
        expect([queuedVault,newerVault,saveVault,deletionVault,cancelVault,isolationVault,deletedSaveVault,ambiguousVault].allSatisfy{$0.allCallsOffMain},"all production-store fixture RPCs stayed off main")
        expect(UserDefaults.standard.persistentDomain(forName:"local.lantern.vnc") as NSDictionary? == productionBefore as NSDictionary?,"owned fixtures leave real application preferences unchanged")
        let report:[String:Any]=["checks":checks,"credentialScope":"synthetic in-memory vault and empty legacy store; no real Keychain",
            "uiScope":"owned offscreen non-key controller; no global input or app activation",
            "restart":"new PersistentPasswordStore/controller restored preferences and authenticated to owned loopback VNC",
            "races":"typed password, endpoint switch, Forget/read, delete/startup, cancel/automatic connect, Stop, queued Save→Forget, queued Forget→Save, Forget/save, late-save cross-endpoint, delete/save, ambiguous save",
            "macOS":ProcessInfo.processInfo.operatingSystemVersionString]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
        print("PASS: \(checks) offscreen nonblocking credential and restart checks")
    }
}
