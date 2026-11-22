#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Build once, then reuse the exact cached signed helper across app updates.
set -euo pipefail
if [[ $# != 4 && $# != 5 ]]; then
  echo 'Usage: build-credential-vault.sh CERTIFICATE_SHA1 ENCRYPTED_P12 PASSWORD_FILE CACHE_DIRECTORY [GENERATION=2]' >&2
  exit 2
fi
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CERTIFICATE_SHA1="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
ENCRYPTED_P12="$2"
PASSWORD_FILE="$3"
CACHE_DIRECTORY="$4"
GENERATION="${5:-2}"
case "$GENERATION" in 1|2) ;; *) echo 'Unsupported credential helper generation.' >&2; exit 2 ;; esac
if [[ ! "$CERTIFICATE_SHA1" =~ ^[a-f0-9]{40}$ || "$CACHE_DIRECTORY" != /* ]]; then
  echo 'Expected a public certificate SHA-1 fingerprint and absolute cache directory.' >&2
  exit 2
fi
if [[ "${LANTERN_VAULT_CACHE_LOCK_HELD:-}" != "$CACHE_DIRECTORY" ]]; then
  # The parent holds this advisory lock for the complete validation/build/
  # publication transaction. Inheriting the descriptor also keeps the lock
  # alive if the wrapper is interrupted while its build child is finishing.
  exec python3 - "$0" "$@" <<'PY'
import fcntl,os,pathlib,subprocess,sys
cache=pathlib.Path(sys.argv[5]);cache.mkdir(parents=True,exist_ok=True,mode=0o700)
cache.chmod(0o700)
fd=os.open(cache/'.build.lock',os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o600)
try:
    fcntl.flock(fd,fcntl.LOCK_EX)
    env=dict(os.environ,LANTERN_VAULT_CACHE_LOCK_HELD=str(cache))
    result=subprocess.run(sys.argv[1:],env=env,pass_fds=(fd,))
    sys.exit(result.returncode)
finally:os.close(fd)
PY
fi
BUNDLE_NAME=LanternCredentialVault.xpc
if [[ "$GENERATION" == 2 ]]; then BUNDLE_NAME=LanternCredentialVaultV2.xpc; fi
APP_DIR="$CACHE_DIRECTORY/$BUNDLE_NAME"
FROZEN_APP_DIR="$APP_DIR"
MANIFEST="$CACHE_DIRECTORY/frozen-manifest.json"
mkdir -p "$CACHE_DIRECTORY"
chmod 700 "$CACHE_DIRECTORY"
SOURCE_HASH="$(python3 - "$PROJECT_DIR" "$GENERATION" <<'PY'
import hashlib, pathlib, sys
root=pathlib.Path(sys.argv[1]);digest=hashlib.sha256()
names=['App/VaultProtocol.swift','App/PasswordStore.swift','native/credential-vault/main.swift']
if sys.argv[2]=='2':names=['App/VaultProtocol.swift','App/PasswordStore.swift','App/VaultV2Protocol.swift','native/credential-vault/v2/main.swift']
for name in names:
    digest.update(name.encode());digest.update(b'\0');digest.update((root/name).read_bytes());digest.update(b'\0')
print(digest.hexdigest())
PY
)"
if [[ -e "$APP_DIR" || -e "$MANIFEST" ]]; then
  python3 - "$MANIFEST" "$APP_DIR" "$SOURCE_HASH" "$CERTIFICATE_SHA1" "$GENERATION" <<'PY'
import hashlib,json,pathlib,sys
manifest,bundle,source_hash,certificate,generation=sys.argv[1:];bundle=pathlib.Path(bundle)
try:
    data=json.loads(pathlib.Path(manifest).read_text())
    assert data['sourceSHA256']==source_hash and data['certificateSHA1']==certificate
    assert data.get('helperGeneration',1)==int(generation)
    assert set(data['files'])=={str(p.relative_to(bundle)) for p in bundle.rglob('*') if p.is_file()}
    for relative,digest in data['files'].items():
        assert hashlib.sha256((bundle/relative).read_bytes()).hexdigest()==digest
except Exception:
    sys.exit('Frozen credential helper differs. Do not rebuild it over existing credentials; review a migration first.')
PY
  codesign --verify --strict --requirement "=identifier \"local.lantern.vnc.credential-vault\" and certificate leaf = H\"$CERTIFICATE_SHA1\"" "$APP_DIR"
  printf '%s\n' "$APP_DIR"
  exit 0
fi
STAGING_DIR="$(mktemp -d "$CACHE_DIRECTORY/.building.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
APP_DIR="$STAGING_DIR/$BUNDLE_NAME"
mkdir -p "$APP_DIR/Contents/MacOS" "$CACHE_DIRECTORY/module-cache"
python3 - "$APP_DIR/Contents/Info.plist" "$CERTIFICATE_SHA1" "$GENERATION" <<'PY'
import pathlib,plistlib,sys
info={'CFBundleIdentifier':'local.lantern.vnc.credential-vault','CFBundleExecutable':'LanternCredentialVault',
      'CFBundleName':'LanternCredentialVault','CFBundlePackageType':'XPC!','CFBundleVersion':sys.argv[3],
      'CFBundleShortVersionString':sys.argv[3]+'.0','LSMinimumSystemVersion':'13.0',
      'LanternVaultClientCertificateSHA1':sys.argv[2],'XPCService':{'ServiceType':'Application'}}
if sys.argv[3]=='2':info['XPCService']['JoinExistingSession']=True
if sys.argv[3]=='2':info['CFBundleIdentifier']='local.lantern.vnc.credential-vault-v2'
pathlib.Path(sys.argv[1]).write_bytes(plistlib.dumps(info,sort_keys=True))
PY
SOURCES=("$PROJECT_DIR/App/VaultProtocol.swift" "$PROJECT_DIR/App/PasswordStore.swift")
if [[ "$GENERATION" == 2 ]]; then
  SOURCES+=("$PROJECT_DIR/App/VaultV2Protocol.swift" "$PROJECT_DIR/native/credential-vault/v2/main.swift")
else
  SOURCES+=("$PROJECT_DIR/native/credential-vault/main.swift")
fi
xcrun swiftc -O -whole-module-optimization -swift-version 5 -target arm64-apple-macosx13.0 \
  -module-cache-path "$CACHE_DIRECTORY/module-cache" -framework Foundation -framework Security \
  "${SOURCES[@]}" -o "$APP_DIR/Contents/MacOS/LanternCredentialVault"
"$PROJECT_DIR/scripts/sign-with-local-identity.sh" "$CERTIFICATE_SHA1" "$ENCRYPTED_P12" "$PASSWORD_FILE" \
  local.lantern.vnc.credential-vault "$APP_DIR"
python3 - "$STAGING_DIR/frozen-manifest.json" "$APP_DIR" "$SOURCE_HASH" "$CERTIFICATE_SHA1" "$GENERATION" <<'PY'
import hashlib,json,pathlib,sys
manifest,bundle,source_hash,certificate,generation=sys.argv[1:];bundle=pathlib.Path(bundle)
data={'sourceSHA256':source_hash,'certificateSHA1':certificate,'helperGeneration':int(generation),'files':{}}
for path in sorted(bundle.rglob('*')):
    if path.is_file():data['files'][str(path.relative_to(bundle))]=hashlib.sha256(path.read_bytes()).hexdigest()
pathlib.Path(manifest).write_text(json.dumps(data,indent=2,sort_keys=True)+'\n')
PY
mv "$APP_DIR" "$FROZEN_APP_DIR"
mv "$STAGING_DIR/frozen-manifest.json" "$MANIFEST"
printf '%s\n' "$FROZEN_APP_DIR"
