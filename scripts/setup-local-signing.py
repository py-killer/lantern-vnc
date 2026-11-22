#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Create one private project identity without Keychain/trust modifications.

The target must be outside the public working tree (normally .git/codex-signing).
Only encrypted key material and a mode0600 wrapping-password file are retained.
Back up that private directory securely; losing it requires a credential-service
migration, not silent key regeneration. This is not Developer ID or notarization.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import sys
import tempfile

os.umask(0o077)
if len(sys.argv) != 2:
    sys.exit('Usage: setup-local-signing.py PRIVATE_DIRECTORY_OUTSIDE_PUBLIC_SOURCE')
project = Path(__file__).resolve().parent.parent
target = Path(sys.argv[1]).resolve()
if target == project or (project in target.parents and '.git' not in target.relative_to(project).parts):
    sys.exit('Signing secrets must be outside the public source tree, or inside its private .git directory.')
target.mkdir(parents=True, exist_ok=True, mode=0o700)
target.chmod(0o700)
metadata = target/'identity.json'
def write_release_config(data):
    path=target/'release-config.json'
    old=json.loads(path.read_text()) if path.exists() else {}
    signer=os.environ.get('RCODESIGN') or old.get('rcodesign')
    if not signer:return
    executable=Path(signer).resolve()
    if not executable.is_file() or not os.access(executable,os.X_OK):
        sys.exit('RCODESIGN must name an independently verified executable.')
    generation=old.get('helperGeneration',1 if str(old.get('helperCache','')).endswith('credential-vault-v1') else 2)
    config={'certSHA1':data['certificateSHA1'],'p12Path':data['p12'],
            'passwordFile':data['passwordFile'],'helperGeneration':generation,
            'helperCache':old.get('helperCache',str(target/('credential-vault-v'+str(generation)))),
            'rcodesign':str(executable)}
    path.write_text(json.dumps(config,indent=2,sort_keys=True)+'\n');path.chmod(0o600)
if metadata.exists():
    data = json.loads(metadata.read_text())
    for name in ['release.p12','release.password','certificate.pem']:
        path=target/name
        if not path.is_file() or path.is_symlink() or path.stat().st_uid != os.geteuid() or path.stat().st_mode & 0o077:
            sys.exit('Existing private signing identity has unsafe permissions or missing files; it was not changed.')
    if hashlib.sha256((target/'release.p12').read_bytes()).hexdigest() != data['encryptedP12SHA256']:
        sys.exit('Existing encrypted identity differs from its metadata; it was not changed.')
    write_release_config(data)
    print(json.dumps(data,indent=2,sort_keys=True));sys.exit(0)
if any(target.iterdir()):
    sys.exit('Refusing to initialize a nonempty directory without identity.json.')

password=secrets.token_urlsafe(64)
env=dict(os.environ,LANTERN_RELEASE_SIGNING_PASSWORD=password)
temporary=Path(tempfile.mkdtemp(prefix='.initializing-',dir=target))
def command(args):
    result=subprocess.run(args,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,timeout=60)
    if result.returncode:
        # Commands never print/export the private key; do not echo their argv
        # or diagnostics nevertheless, because this is a private-key operation.
        raise RuntimeError('Private signing identity generation failed (exit '+str(result.returncode)+').')
    return result.stdout
try:
    config=temporary/'certificate.cnf'
    config.write_text('[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=Lantern VNC Local Release Signing\nO=Lantern VNC Project\n[ext]\nbasicConstraints=critical,CA:true\nkeyUsage=critical,digitalSignature,keyCertSign,cRLSign\nextendedKeyUsage=critical,codeSigning\n')
    private_key=temporary/'encrypted-key.pem'
    certificate=temporary/'certificate.pem'
    p12=temporary/'release.p12'
    command(['/usr/bin/openssl','req','-x509','-newkey','rsa:3072','-sha256','-days','3650',
             '-config',str(config),'-keyout',str(private_key),'-out',str(certificate),
             '-passout','env:LANTERN_RELEASE_SIGNING_PASSWORD'])
    command(['/usr/bin/openssl','pkcs12','-export','-inkey',str(private_key),'-in',str(certificate),
             '-out',str(p12),'-name','Lantern VNC Local Release Signing',
             '-passin','env:LANTERN_RELEASE_SIGNING_PASSWORD','-passout','env:LANTERN_RELEASE_SIGNING_PASSWORD'])
    fingerprint=command(['/usr/bin/openssl','x509','-in',str(certificate),'-noout','-sha1','-fingerprint']).strip().split('=')[-1].replace(':','').lower()
    assert re.fullmatch('[a-f0-9]{40}',fingerprint)
    validity=command(['/usr/bin/openssl','x509','-in',str(certificate),'-noout','-dates']).strip().splitlines()
    data={'certificateSHA1':fingerprint,'validity':validity,'algorithm':'RSA3072/SHA256; codeSigning EKU',
          'encryptedP12SHA256':hashlib.sha256(p12.read_bytes()).hexdigest(),
          'p12':str(target/'release.p12'),'passwordFile':str(target/'release.password'),
          'publicCertificate':str(target/'certificate.pem'),
          'backup':'Securely back up this complete private directory; never publish it or regenerate silently.',
          'trustSettingsChanged':False,'developerID':False,'notarized':False}
    for source,name in [(p12,'release.p12'),(certificate,'certificate.pem')]:
        shutil.move(source,target/name);(target/name).chmod(0o600)
    (target/'release.password').write_text(password);(target/'release.password').chmod(0o600)
    metadata.write_text(json.dumps(data,indent=2,sort_keys=True)+'\n');metadata.chmod(0o600)
    write_release_config(data)
    print(json.dumps(data,indent=2,sort_keys=True))
finally:
    shutil.rmtree(temporary)
