#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Real NSXPC + Security proof; private generated keys and fake credentials only.

Never registers a login item, changes trust/search lists, reads an existing
Keychain item, activates an app, or sends global input. All fixture apps are
under .noindex and never installed. Requires an independently verified signer.
"""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shutil
import signal
import subprocess
import sys
import time
import uuid

os.umask(0o077)
project = Path(sys.argv[1]).resolve()
signer = Path(sys.argv[2]).resolve()
work = project.parent / 'work/vault-xpc-tests'
run = work / 'fixtures.noindex' / ('run-' + uuid.uuid4().hex)
run.mkdir(parents=True, mode=0o700)
module_cache = work / 'module-cache'
module_cache.mkdir(parents=True, exist_ok=True)
keychain = run / 'synthetic.keychain-db'
lifecycle = run / 'helper-lifecycle.txt'
password = secrets.token_urlsafe(48)
env = dict(os.environ, LANTERN_VAULT_FIXTURE_PASSWORD=password)
checks = 0
report = {'scope':'owned fixture apps and private synthetic Keychain only',
          'trustOrSearchListChanges':False, 'realCredentialReads':0, 'globalInputEvents':0,
          'stages':[], 'directory':str(run)}
setup = run / 'fixture-setup'

def expect(value, label):
    global checks
    checks += 1
    if not value:
        raise AssertionError(label)
    print('PASS: ' + label, flush=True)

def command(stage, args, *, input_text=None, allow_failure=False, timeout=45):
    result = subprocess.run(list(map(str,args)), input=input_text, env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=timeout)
    row = {'stage':stage, 'exit':result.returncode}
    if stage.startswith(('worker-', 'verify-', 'create-keychain', 'delete-keychain')) or result.returncode:
        # Signing tools never receive a password in argv and are never asked
        # to print/export keys. Avoid retaining verbose signing output anyway.
        row['output'] = (result.stdout+result.stderr).strip()[:4000]
    report['stages'].append(row)
    if result.returncode and not allow_failure:
        raise RuntimeError(stage + ' failed: ' + row.get('output',''))
    return result

def swift(stage, inputs, output, extra=()):
    return command(stage, ['xcrun','swiftc','-O','-swift-version','5','-target','arm64-apple-macosx13.0',
                          '-module-cache-path',module_cache,'-framework','Foundation','-framework','Security',
                          *extra,*inputs,'-o',output])

def certificate(prefix):
    config=run/(prefix+'.cnf')
    config.write_text('[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=Lantern isolated XPC '+prefix+'\n[ext]\nbasicConstraints=critical,CA:true\nkeyUsage=critical,digitalSignature,keyCertSign,cRLSign\nextendedKeyUsage=critical,codeSigning\n')
    key=run/(prefix+'-encrypted.pem');cert=run/(prefix+'.pem');p12=run/(prefix+'.p12')
    command('generate-'+prefix,['/usr/bin/openssl','req','-x509','-newkey','rsa:2048','-sha256','-days','2',
                              '-config',config,'-keyout',key,'-out',cert,'-passout','env:LANTERN_VAULT_FIXTURE_PASSWORD'])
    command('wrap-'+prefix,['/usr/bin/openssl','pkcs12','-export','-inkey',key,'-in',cert,'-out',p12,
                          '-passin','env:LANTERN_VAULT_FIXTURE_PASSWORD','-passout','env:LANTERN_VAULT_FIXTURE_PASSWORD'])
    key.unlink()
    fingerprint=command('certificate-metadata-'+prefix,['/usr/bin/openssl','x509','-in',cert,'-noout','-sha1','-fingerprint']).stdout.strip().split('=')[-1].replace(':','').lower()
    assert re.fullmatch('[a-f0-9]{40}',fingerprint)
    return p12,fingerprint

def sign(bundle,p12,fingerprint,identifier):
    expression='identifier "'+identifier+'" and certificate leaf = H"'+fingerprint+'"'
    compiled=run/(uuid.uuid4().hex+'.csreq')
    command('compile-requirement',['/usr/bin/csreq','-r','='+expression,'-b',compiled])
    command('sign-'+bundle.name,[signer,'sign','--config-file','/dev/null','--timestamp-url','none','--exclude','**',
                               '--p12-file',p12,'--p12-password-file','/dev/stdin','--code-requirements-file',compiled,bundle],input_text=password)
    command('verify-'+bundle.name,['/usr/bin/codesign','--verify','--strict','--requirement','='+expression,bundle])

def cdhash(bundle):
    text=command('display-signature',['/usr/bin/codesign','-d','--verbose=4',bundle]).stderr
    match=re.search(r'^CDHash=([a-f0-9]+)$',text,re.M)
    assert match,text
    return match.group(1)

def files(bundle):
    return {str(p.relative_to(bundle)):hashlib.sha256(p.read_bytes()).hexdigest()
            for p in bundle.rglob('*') if p.is_file()}

def methods():
    if not lifecycle.exists():return []
    return [line for line in lifecycle.read_text().splitlines() if line.split()[-1] in ['read','save','remove']]

def stop_owned_helper():
    if not lifecycle.exists():return True
    pids={int(line.split()[0]) for line in lifecycle.read_text().splitlines() if line.endswith(' start')}
    for pid in pids:
        result=subprocess.run(['/bin/ps','-p',str(pid),'-o','command='],capture_output=True,text=True)
        if result.returncode:continue
        if str(run) not in result.stdout or 'LanternCredentialVault' not in result.stdout:
            continue
        os.kill(pid,signal.SIGTERM)
        deadline=time.monotonic()+3
        while time.monotonic()<deadline:
            current=subprocess.run(['/bin/ps','-p',str(pid),'-o','command='],capture_output=True,text=True)
            if current.returncode:break
            time.sleep(.03)
    for pid in pids:
        current=subprocess.run(['/bin/ps','-p',str(pid),'-o','command='],capture_output=True,text=True)
        if current.returncode==0 and str(run) in current.stdout and 'LanternCredentialVault' in current.stdout:
            return False
    return True

def cleanup_fixture_apps():
    # Executing an app for the XPC proof can register it in LaunchServices even
    # inside .noindex. Unregister exact owned paths before removing fixtures;
    # never reset the registry or touch an installed Lantern app.
    registry='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
    removed=0;unregistered=0;already_absent=0
    for bundle in sorted(run.rglob('LanternVaultHarness.app')):
        if bundle.is_symlink() or run not in bundle.resolve().parents:
            raise RuntimeError('Refusing cleanup outside the owned fixture run')
        info=plistlib.loads((bundle/'Contents/Info.plist').read_bytes())
        if info.get('CFBundleName')!='VaultHarness' or info.get('CFBundleExecutable')!='VaultHarness' or info.get('CFBundleIdentifier') not in ['local.lantern.vnc','local.lantern.untrusted']:
            raise RuntimeError('Refusing cleanup of an unknown app bundle')
        result=subprocess.run([registry,'-u',str(bundle)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,timeout=20)
        diagnostic=(result.stdout+result.stderr).strip()
        # This exact error means an otherwise validated owned fixture was
        # never registered (for example, rejected before its first XPC lookup).
        # All other failures remain fatal; do not reset the shared registry.
        absent=result.returncode==1 and re.fullmatch(re.escape('failed to scan '+str(bundle)+': -10814')+r'\s+from spotlight',diagnostic) is not None
        if result.returncode and not absent:
            raise RuntimeError('Exact-path fixture unregistration failed')
        if absent:already_absent+=1
        else:unregistered+=1
        shutil.rmtree(bundle);removed+=1
    report['unregisteredFixtureApps']=unregistered
    report['alreadyUnregisteredFixtureApps']=already_absent
    report['removedFixtureApps']=removed

def app(name,binary,helper,certificate_pin,helper_hash,p12,signing_pin,identifier='local.lantern.vnc',ad_hoc=False):
    bundle=run/name/'LanternVaultHarness.app'
    (bundle/'Contents/MacOS').mkdir(parents=True)
    (bundle/'Contents/XPCServices').mkdir()
    shutil.copy2(binary,bundle/'Contents/MacOS/VaultHarness')
    shutil.copytree(helper,bundle/'Contents/XPCServices/LanternCredentialVault.xpc')
    info={'CFBundleIdentifier':identifier,'CFBundleExecutable':'VaultHarness','CFBundleName':'VaultHarness',
          'CFBundlePackageType':'APPL','CFBundleVersion':'1','LSMinimumSystemVersion':'13.0',
          'LanternVaultClientCertificateSHA1':certificate_pin,'LanternVaultServiceCDHash':helper_hash}
    (bundle/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    if ad_hoc:
        command('sign-adhoc',['/usr/bin/codesign','--force','--sign','-','--identifier',identifier,bundle])
    else:sign(bundle,p12,signing_pin,identifier)
    return bundle

def worker(bundle,action):
    return command('worker-'+bundle.parent.name+'-'+action,[bundle/'Contents/MacOS/VaultHarness',action],timeout=15)

try:
    swift('compile-owned-keychain-setup',[project/'tests/vault_fixture_setup.swift'],setup)
    command('create-keychain',[setup],input_text=json.dumps({'action':'create','path':str(keychain),'password':password}))
    p12,pin=certificate('project')
    wrong_p12,wrong_pin=certificate('wrong')
    (run/'keychain.password').write_text(password)
    helper=run/'frozen/LanternCredentialVault.xpc'
    (helper/'Contents/MacOS').mkdir(parents=True)
    helper_info={'CFBundleIdentifier':'local.lantern.vnc.credential-vault','CFBundleExecutable':'LanternCredentialVault',
                 'CFBundleName':'LanternCredentialVault','CFBundlePackageType':'XPC!','CFBundleVersion':'1',
                 'LSMinimumSystemVersion':'13.0','LanternVaultClientCertificateSHA1':pin,
                 'LanternVaultTestKeychain':str(keychain),'LanternVaultTestService':'local.lantern.synthetic-lab.'+uuid.uuid4().hex,
                 'LanternVaultTestKeychainPasswordFile':str(run/'keychain.password'),
                 'LanternVaultTestLifecycleFile':str(lifecycle),'XPCService':{'ServiceType':'Application'}}
    (helper/'Contents/Info.plist').write_bytes(plistlib.dumps(helper_info))
    swift('compile-test-helper',[project/'App/VaultProtocol.swift',project/'App/PasswordStore.swift',
                                project/'native/credential-vault/main.swift'],helper/'Contents/MacOS/LanternCredentialVault',['-D','VAULT_HARNESS'])
    sign(helper,p12,pin,'local.lantern.vnc.credential-vault')
    helper_hash=cdhash(helper);helper_files=files(helper)
    binaries={}
    for version in ['A','B']:
        source=run/(version+'.swift')
        source.write_text((project/'tests/vault_harness.swift').read_text().replace('LANTERN_VAULT_BUILD_MARKER',version))
        binary=run/('client-'+version)
        swift('compile-client-'+version,[project/'App/VaultProtocol.swift',project/'App/VaultV2Protocol.swift',project/'App/PasswordStore.swift',
                                        project/'App/CredentialVaultClient.swift',source],binary)
        binaries[version]=binary
    a=app('A',binaries['A'],helper,pin,helper_hash,p12,pin)
    b=app('B',binaries['B'],helper,pin,helper_hash,p12,pin)
    expect(cdhash(a)!=cdhash(b),'main binaries A/B have different code hashes')
    expect(files(a/'Contents/XPCServices/LanternCredentialVault.xpc')==helper_files==files(b/'Contents/XPCServices/LanternCredentialVault.xpc'),
           'A/B embed the byte-identical frozen helper after main signing')
    worker(a,'write');expect(True,'A saves and reads only its synthetic endpoint via real authenticated XPC')
    first_pid=int(lifecycle.read_text().splitlines()[-1].split()[0])
    stop_owned_helper()
    worker(b,'read');expect(True,'B reads A credential after main and helper restart')
    last_pid=int(lifecycle.read_text().splitlines()[-1].split()[0])
    expect(first_pid!=last_pid,'restarted helper uses a different process with the same code identity')
    worker(b,'update');expect(True,'B updates credential with host/port isolation through the frozen helper')
    moved=run/'Moved'/'LanternVaultHarness.app';moved.parent.mkdir();shutil.move(a,moved)
    worker(moved,'read');expect(True,'moving the legitimate app retains authenticated credential access')
    stop_owned_helper()
    for name,key,cert,identifier,ad_hoc in [
        ('WrongCertificate',wrong_p12,wrong_pin,'local.lantern.vnc',False),
        ('WrongIdentifier',p12,pin,'local.lantern.untrusted',False),
        ('AdHoc',p12,pin,'local.lantern.vnc',True)]:
        bad=app(name,binaries['B'],helper,pin,helper_hash,key,cert,identifier,ad_hoc)
        before=len(methods());worker(bad,'deny');expect(len(methods())==before,name+' is rejected before any vault item operation')
        stop_owned_helper()
    replacement=run/'replacement/LanternCredentialVault.xpc'
    replacement.parent.mkdir();shutil.copytree(helper,replacement)
    info=plistlib.loads((replacement/'Contents/Info.plist').read_bytes());info['CFBundleVersion']='2'
    (replacement/'Contents/Info.plist').write_bytes(plistlib.dumps(info));sign(replacement,p12,pin,'local.lantern.vnc.credential-vault')
    substituted=app('SubstitutedHelper',binaries['B'],replacement,pin,helper_hash,p12,pin)
    before=len(methods());worker(substituted,'deny');expect(len(methods())==before,'same-certificate substituted helper is rejected by pinned helper hash')
    worker(b,'delete');expect(True,'B deletes and confirms missing items after updating/restarting main')
    expect(files(helper)==helper_files,'all fixture operations leave frozen helper bytes unchanged')
    report.update(result='pass',checks=checks,helperCDHash=helper_hash,helperRestartsVerified=True,
                  successfulItemOperations=len(methods()),publisherCertificateSHA1=pin)
except Exception as error:
    report.update(result='fail',checks=checks,errorType=type(error).__name__,error=str(error)[:4000])
    print('FAIL: '+str(error),flush=True)
finally:
    if stop_owned_helper():
        try:cleanup_fixture_apps()
        except Exception as error:report['fixtureCleanupFailure']=type(error).__name__
    else:report['fixtureCleanupFailure']='OwnedHelperStillRunning'
    if setup.exists() and keychain.exists():
        try:command('delete-keychain',[setup],input_text=json.dumps({'action':'delete','path':str(keychain)}))
        except Exception as error:report['cleanupFailure']=type(error).__name__
    for p in run.glob('*.p12'):p.unlink()
    for p in run.glob('*-encrypted.pem'):p.unlink()
    (run/'keychain.password').unlink(missing_ok=True)
    report_path=work/'vault-xpc-report.json'
    report_path.write_text(json.dumps(report,indent=2,sort_keys=True)+'\n')
    print('Report: '+str(report_path),flush=True)
sys.exit(0 if report.get('result')=='pass' and 'cleanupFailure' not in report and 'fixtureCleanupFailure' not in report else 1)
