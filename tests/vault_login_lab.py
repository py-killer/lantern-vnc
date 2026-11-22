#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""No-unlock PUBLICv2 login-Keychain proof using only newly owned UUID items."""
import hashlib,json,os,plistlib,re,select,shutil,signal,subprocess,sys,time,uuid
from pathlib import Path
os.umask(0o077)
project=Path(sys.argv[1]).resolve();config=json.loads(Path(sys.argv[2]).read_text());cache=Path(sys.argv[3]).resolve()
work=project.parent/'work/vault-login-tests';run=work/'fixtures.noindex'/('run-'+uuid.uuid4().hex);run.mkdir(parents=True,mode=0o700)
host='synthetic-vault-'+uuid.uuid4().hex+'.invalid';helper_name='LanternCredentialVaultV2.xpc'
public=cache/helper_name;manifest=json.loads((cache/'frozen-manifest.json').read_text())
env=dict(os.environ,RCODESIGN=config['rcodesign']);checks=0
report={'scope':'PUBLICv2 helper, default login Keychain, new UUID synthetic endpoints only','unlockCalls':0,'ownerEndpointQueries':0,'ownerPreferencesWrites':0,'stages':[]}
apps=[];owned_pids=set();b=None;cleaned=False;seed=None;legacy_host='synthetic-vault-'+uuid.uuid4().hex+'.invalid';legacy_cleaned=False
def command(stage,args,allow=False,extra_env=None):
 result=subprocess.run(list(map(str,args)),env=extra_env or env,capture_output=True,text=True,timeout=45)
 row={'stage':stage,'exit':result.returncode}
 if result.returncode or stage.startswith('worker'):row['output']=(result.stdout+result.stderr).strip()[:2000]
 report['stages'].append(row)
 if result.returncode and not allow:raise RuntimeError(stage+': '+row.get('output',''))
 return result
def expect(value,label):
 global checks
 checks+=1
 if not value:raise AssertionError(label)
 print('PASS: '+label,flush=True)
def sign(bundle,identifier='local.lantern.vnc',adhoc=False,signing=None):
 if adhoc:command('sign-adhoc',['codesign','--force','--sign','-','--identifier',identifier,bundle]);return
 signing=signing or config
 requirement='identifier "'+identifier+'" and certificate leaf = H"'+signing['certSHA1']+'"'
 req=run/(uuid.uuid4().hex+'.csreq');command('compile-requirement',['csreq','-r','='+requirement,'-b',req])
 command('sign',[signing['rcodesign'],'sign','--config-file','/dev/null','--timestamp-url','none','--exclude','**','--p12-file',signing['p12Path'],'--p12-password-file',signing['passwordFile'],'--code-requirements-file',req,bundle])
 command('verify',['codesign','--verify','--deep','--strict','--requirement','='+requirement,bundle])
def tree(path):return {str(p.relative_to(path)):hashlib.sha256(p.read_bytes()).hexdigest() for p in path.rglob('*') if p.is_file()}
def hashcode(path):
 output=command('signature',['codesign','-d','--verbose=4',path]).stderr
 return re.search(r'^CDHash=([a-f0-9]+)$',output,re.M).group(1)
def make_app(name,binary,identifier='local.lantern.vnc',adhoc=False,signing=None):
 bundle=run/name/'VaultLoginHarness.app';(bundle/'Contents/MacOS').mkdir(parents=True);(bundle/'Contents/XPCServices').mkdir()
 shutil.copy2(binary,bundle/'Contents/MacOS/VaultLoginHarness');shutil.copytree(public,bundle/'Contents/XPCServices'/helper_name)
 info={'CFBundleIdentifier':identifier,'CFBundleExecutable':'VaultLoginHarness','CFBundleName':'VaultLoginHarness','CFBundlePackageType':'APPL','CFBundleVersion':'1','LSMinimumSystemVersion':'13.0','LanternVaultClientCertificateSHA1':config['certSHA1'],'LanternVaultServiceCDHash':hashcode(public),'LanternVaultServiceGeneration':2}
 (bundle/'Contents/Info.plist').write_bytes(plistlib.dumps(info));sign(bundle,identifier,adhoc,signing);apps.append(bundle);return bundle
def worker(bundle,action,hold=False,endpoint=None):
 executable=bundle/'Contents/MacOS/VaultLoginHarness'
 target=endpoint or host
 if not hold:return command('worker-'+action,[executable,action,target])
 process=subprocess.Popen([str(executable),action,target],env=dict(env,LANTERN_LOGIN_HOLD='1'),stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,bufsize=1)
 deadline=time.monotonic()+12;output=''
 try:
  while time.monotonic()<deadline and process.poll() is None:
   ready,_,_=select.select([process.stdout],[],[],.1)
   if ready:
    chunk=os.read(process.stdout.fileno(),4096).decode('utf8')
    output+=chunk
    if 'READY\n' in output:break
  assert 'READY\n' in output,'owned worker did not reach hold: '+output
  processes=command('owned-pid-metadata',['ps','-axo','pid,comm']).stdout
  helpers=[int(line.strip().split(' ',1)[0]) for line in processes.splitlines() if str(bundle) in line and '/Contents/MacOS/LanternCredentialVault' in line]
  assert len(helpers)==1,helpers
  pid=helpers[0];owned_pids.add(pid)
  def audit(pid):
   text=command('audit-session',['launchctl','print','pid/'+str(pid)]).stdout
   return int(re.search(r'\basid\s*=\s*(\d+)',text).group(1))
  main_session,helper_session=audit(process.pid),audit(pid)
  expect(main_session==helper_session,'PUBLIC helper shares the main login security session')
  report.setdefault('sessionPairs',[]).append({'main':main_session,'helper':helper_session})
  return pid
 finally:
  if process.poll() is None:
   process.stdin.write('\n');process.stdin.flush()
  tail,_=process.communicate(timeout=8)
  if process.returncode:raise RuntimeError('owned worker failed: '+output+tail)
def stop_owned():
 snapshot=subprocess.run(['ps','-axo','pid,comm'],capture_output=True,text=True)
 if snapshot.returncode==0:
  for line in snapshot.stdout.splitlines():
   if str(run) in line and '/Contents/MacOS/LanternCredentialVault' in line:
    owned_pids.add(int(line.strip().split(' ',1)[0]))
 for pid in list(owned_pids):
  result=subprocess.run(['ps','-p',str(pid),'-o','command='],capture_output=True,text=True)
  if result.returncode==0 and str(run) in result.stdout and 'LanternCredentialVault' in result.stdout:
   os.kill(pid,signal.SIGTERM)
   deadline=time.monotonic()+3
   while time.monotonic()<deadline and subprocess.run(['ps','-p',str(pid)],capture_output=True).returncode==0:time.sleep(.03)
def cleanup_apps():
 registry='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
 for bundle in apps:
  if not bundle.exists():continue
  assert run in bundle.resolve().parents and not bundle.is_symlink()
  info=plistlib.loads((bundle/'Contents/Info.plist').read_bytes());assert info['CFBundleName']=='VaultLoginHarness'
  result=subprocess.run([registry,'-u',str(bundle)],capture_output=True,text=True)
  text=(result.stdout+result.stderr).strip()
  absent=result.returncode==1 and re.fullmatch(re.escape('failed to scan '+str(bundle)+': -10814')+r'\s+from spotlight',text)
  assert result.returncode==0 or absent,text
  shutil.rmtree(bundle)
try:
 expect(manifest.get('helperGeneration')==2 and tree(public)==manifest['files'],'frozen PUBLICv2 bundle matches its published build manifest')
 info=plistlib.loads((public/'Contents/Info.plist').read_bytes());expect(info['XPCService'].get('JoinExistingSession') is True,'PUBLIC helper explicitly joins the existing security session')
 data=(public/'Contents/MacOS/LanternCredentialVault').read_bytes()
 expect(not any(s in data for s in [b'LanternVaultTestKeychain',b'LANTERN_VAULT_TEST_KEYCHAIN',b'unlock-owned-keychain']),'PUBLIC helper contains no private-Keychain test or unlock hooks')
 for version in ['A','B']:
  source=run/(version+'.swift');source.write_text((project/'tests/vault_login_harness.swift').read_text().replace('LANTERN_LOGIN_BUILD',version))
  binary=run/('client-'+version)
  command('compile-'+version,['xcrun','swiftc','-O','-swift-version','5','-target','arm64-apple-macosx13.0','-module-cache-path',work/'module-cache','-framework','Foundation','-framework','Security',project/'App/VaultProtocol.swift',project/'App/VaultV2Protocol.swift',project/'App/PasswordStore.swift',project/'App/CredentialVaultClient.swift',source,'-o',binary])
  if version=='A':a=make_app(version,binary)
  else:b=make_app(version,binary)
 expect(hashcode(a)!=hashcode(b),'different signed main versions preserve the exact helper bytes')
 first=worker(a,'write',True);expect(True,'A saves and reads a fake UUID credential in the DEFAULT login Keychain without unlocking it')
 stop_owned();second=worker(b,'read',True);expect(first!=second,'B reads the same fake credential after both main and helper restart')
 worker(b,'update');expect(True,'changed main version preserves per-port isolation')
 for name,identifier,adhoc in [('WrongID','local.lantern.untrusted',False),('AdHoc','local.lantern.vnc',True)]:
  bad=make_app(name,run/'client-B',identifier,adhoc);worker(bad,'deny');expect(True,name+' cannot access PUBLIC helper')
 wrong=run/'wrong-publisher'
 command('generate-owned-wrong-publisher',['python3',project/'scripts/setup-local-signing.py',wrong])
 wrong_config=json.loads((wrong/'release-config.json').read_text())
 bad=make_app('WrongCertificate',run/'client-B',signing=wrong_config);worker(bad,'deny')
 expect(True,'a correctly named main signed with another certificate cannot access PUBLIC helper')
 bad=make_app('SubstitutedHelper',run/'client-B')
 replacement=bad/'Contents/XPCServices'/helper_name
 replaced=plistlib.loads((replacement/'Contents/Info.plist').read_bytes());replaced['CFBundleVersion']='999'
 (replacement/'Contents/Info.plist').write_bytes(plistlib.dumps(replaced))
 command('sign-owned-substituted-helper',[project/'scripts/sign-with-local-identity.sh',config['certSHA1'],config['p12Path'],config['passwordFile'],'local.lantern.vnc.credential-vault',replacement])
 sign(bad);worker(bad,'deny');expect(True,'same-publisher substituted helper is rejected by exact hash pin')
 worker(b,'delete');cleaned=True;expect(True,'the unchanged PUBLIC helper deletes all synthetic login items and confirms absence')
 seed=run/'legacy-seed'
 command('compile-owned-legacy-seed',['xcrun','swiftc','-O','-swift-version','5','-target','arm64-apple-macosx13.0','-module-cache-path',work/'module-cache','-framework','Foundation','-framework','Security',project/'App/VaultProtocol.swift',project/'App/VaultV2Protocol.swift',project/'App/PasswordStore.swift',project/'tests/vault_login_seed.swift','-o',seed])
 command('sign-owned-legacy-seed',[project/'scripts/sign-with-local-identity.sh',config['certSHA1'],config['p12Path'],config['passwordFile'],'local.lantern.vnc.credential-vault',seed])
 command('seed-owned-v1-UUID',[seed,'write',legacy_host])
 legacy_result=worker(b,'legacy',endpoint=legacy_host)
 report['legacyReadOutcome']='protected' if 'LEGACY_PROTECTED:' in legacy_result.stdout else 'authorized'
 command('verify-owned-v1-after-read',[seed,'read',legacy_host])
 expect(True,'explicit legacy read is authorized or safely denied while normal read remains v2-only and the old item is intact')
 worker(b,'write',endpoint=legacy_host);worker(b,'delete',endpoint=legacy_host)
 worker(b,'legacy',endpoint=legacy_host);command('verify-owned-v1-untouched',[seed,'read',legacy_host])
 expect(True,'v2 save/delete neither mutates legacy data nor automatically resurrects it')
 command('cleanup-owned-v1-UUID',[seed,'delete',legacy_host]);legacy_cleaned=True
 expect(tree(public)==manifest['files'],'production cache remains byte-identical after all calls')
 report.update(result='pass',checks=checks,helperCDHash=hashcode(public),syntheticItemsCleaned=True)
except Exception as error:
 report.update(result='fail',checks=checks,errorType=type(error).__name__,error=str(error)[:3000]);print('FAIL: '+str(error),flush=True)
finally:
 if b is not None and not cleaned:
  try:worker(b,'delete');report['syntheticItemsCleaned']=True
  except Exception as error:report['syntheticCleanupFailure']=type(error).__name__
 if seed is not None and not legacy_cleaned:
  try:
   if b is not None:worker(b,'delete',endpoint=legacy_host)
   command('cleanup-owned-v1-UUID',[seed,'delete',legacy_host]);report['legacySyntheticItemsCleaned']=True
  except Exception as error:report['legacySyntheticCleanupFailure']=type(error).__name__
 elif legacy_cleaned:report['legacySyntheticItemsCleaned']=True
 stop_owned()
 try:cleanup_apps();report['fixtureAppsRemoved']=True
 except Exception as error:report['fixtureCleanupFailure']=type(error).__name__
 if (run/'wrong-publisher').exists():shutil.rmtree(run/'wrong-publisher')
 (work/'vault-login-report.json').write_text(json.dumps(report,indent=2,sort_keys=True)+'\n')
 print('Report: '+str(work/'vault-login-report.json'),flush=True)
sys.exit(0 if report.get('result')=='pass' and not any(k.endswith('Failure') for k in report) else 1)
