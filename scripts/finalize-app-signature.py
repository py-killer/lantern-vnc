#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Seal the viewer while preserving its immutable credential service."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys

project = Path(__file__).resolve().parent.parent
if len(sys.argv) != 2:
    sys.exit('Usage: finalize-app-signature.py APP_DIRECTORY')
app = Path(sys.argv[1]).resolve()
info_path = app / 'Contents/Info.plist'
info = plistlib.loads(info_path.read_bytes())
if info.get('CFBundleIdentifier') != 'local.lantern.vnc':
    sys.exit('Refusing to sign a different application identifier.')
explicit = os.environ.get('LANTERN_SIGNING_CONFIG')
config_path = Path(explicit) if explicit else project / '.git/codex-signing/release-config.json'
helper_target = app / 'Contents/XPCServices/LanternCredentialVaultV2.xpc'
previous_helper = app / 'Contents/XPCServices/LanternCredentialVault.xpc'

def files(root):
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(root.rglob('*')) if p.is_file()}

if not config_path.exists():
    if explicit:
        sys.exit('The explicitly configured private signing file is unavailable.')
    # A source checkout can still build and test the desktop without release
    # signing material. Never present its ad hoc identity as a trusted vault.
    info.pop('LanternVaultClientCertificateSHA1', None)
    info.pop('LanternVaultServiceCDHash', None)
    info_path.write_bytes(plistlib.dumps(info,sort_keys=False))
    for obsolete in [helper_target,previous_helper]:
        if obsolete.exists(): shutil.rmtree(obsolete)
    subprocess.run(['codesign','--force','--sign','-','--identifier','local.lantern.vnc',str(app)],check=True)
    print('Development signature: persistent credential service is unavailable. See native/credential-vault/README.md.',file=sys.stderr)
    sys.exit(0)

metadata = config_path.stat()
if config_path.is_symlink() or metadata.st_uid != os.geteuid() or metadata.st_mode & 0o077:
    sys.exit('The private signing configuration must be owned by this user with mode0600 or stricter.')
config = json.loads(config_path.read_text())
if config.get('helperGeneration') != 2:
    sys.exit('This viewer requires credential service generation2. Preserve the original cache and configure the verified v2 cache.')
certificate = config['certSHA1'].lower()
if re.fullmatch('[0-9a-f]{40}',certificate) is None:
    sys.exit('Invalid public publisher certificate fingerprint.')
signer = Path(config['rcodesign'])
# Pinned arm64 build tool, never bundled with the viewer or source archive.
if hashlib.sha256(signer.read_bytes()).hexdigest() != '6c4623db45f1d89af439a2ce42fd65798ef56aaaa3e4ced48879be05f750aacb':
    sys.exit('The publisher signing tool does not match the verified rcodesign0.29.0 arm64 binary.')
environment = dict(os.environ,RCODESIGN=str(signer))
subprocess.run([str(project/'scripts/build-credential-vault.sh'),certificate,config['p12Path'],config['passwordFile'],config['helperCache'],'2'],env=environment,check=True)
helper = Path(config['helperCache'])/'LanternCredentialVaultV2.xpc'
helper_info=plistlib.loads((helper/'Contents/Info.plist').read_bytes())
if helper_info.get('XPCService',{}).get('JoinExistingSession') is not True:
    sys.exit('The credential service must join the existing user security session.')
if helper_info.get('CFBundleIdentifier') != 'local.lantern.vnc.credential-vault-v2':
    sys.exit('Unexpected current credential service bundle identifier.')
before = files(helper)
helper_target.parent.mkdir(parents=True,exist_ok=True)
if helper_target.exists():
    shutil.rmtree(helper_target)
if previous_helper.exists():
    shutil.rmtree(previous_helper)
shutil.copytree(helper,helper_target)
display = subprocess.run(['codesign','--display','--verbose=4',str(helper_target)],capture_output=True,text=True,check=True)
match = re.search(r'^CDHash=([0-9a-fA-F]+)$',display.stderr,re.MULTILINE)
if match is None:
    sys.exit('Unable to read the immutable helper code hash.')
info['LanternVaultClientCertificateSHA1'] = certificate
info['LanternVaultServiceCDHash'] = match.group(1).lower()
info_path.write_bytes(plistlib.dumps(info,sort_keys=False))
subprocess.run([str(project/'scripts/sign-with-local-identity.sh'),certificate,config['p12Path'],config['passwordFile'],'local.lantern.vnc',str(app)],env=environment,check=True)
if files(helper_target) != before:
    sys.exit('Main-app signing changed the credential helper; refusing this package.')
subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
print('Publisher signature verified; immutable credential service preserved.')
