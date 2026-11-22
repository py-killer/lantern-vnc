#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Pins a private project's existing signing certificate without changing any
# trust settings or Keychain search list. No password is accepted by this tool.
set -euo pipefail
if [[ $# != 5 ]]; then
  echo 'Usage: sign-with-local-identity.sh CERTIFICATE_SHA1 ENCRYPTED_P12 PASSWORD_FILE IDENTIFIER CODE_PATH' >&2
  exit 2
fi
CERTIFICATE_SHA1="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
ENCRYPTED_P12="$2"
PASSWORD_FILE="$3"
IDENTIFIER="$4"
CODE_PATH="$5"
SIGNER="${RCODESIGN:?Set RCODESIGN to the verified private build-tool executable.}"
python3 - "$ENCRYPTED_P12" "$PASSWORD_FILE" <<'PY'
import os,pathlib,sys
for name in sys.argv[1:]:
    path=pathlib.Path(name);info=path.stat()
    if not path.is_file() or path.is_symlink() or info.st_uid!=os.geteuid() or info.st_mode & 0o077:
        sys.exit('Signing secret files must be owned by this user with mode0600 or stricter.')
PY
if [[ ! "$CERTIFICATE_SHA1" =~ ^[a-f0-9]{40}$ ]]; then
  echo 'Pass the public SHA-1 fingerprint of the project signing certificate.' >&2
  exit 2
fi
case "$IDENTIFIER" in
  local.lantern.vnc|local.lantern.vnc.credential-vault) ;;
  *) echo 'Unexpected Lantern code identifier.' >&2; exit 2 ;;
esac
REQUIREMENT="identifier \"$IDENTIFIER\" and certificate leaf = H\"$CERTIFICATE_SHA1\""
COMPILED_REQUIREMENT="$(mktemp "${TMPDIR:-/tmp}/lantern-vault-requirement.XXXXXX")"
trap 'rm -f "$COMPILED_REQUIREMENT"' EXIT
csreq -r "=$REQUIREMENT" -b "$COMPILED_REQUIREMENT"
# Explicitly preserve nested bundles, including the immutable credential
# helper. Disable default config files and timestamp networking.
"$SIGNER" sign --config-file /dev/null --timestamp-url none --exclude '**' \
  --p12-file "$ENCRYPTED_P12" --p12-password-file "$PASSWORD_FILE" \
  --binary-identifier "$IDENTIFIER" --code-requirements-file "$COMPILED_REQUIREMENT" "$CODE_PATH"
if [[ -d "$CODE_PATH/Contents" ]]; then
  BUNDLE_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$CODE_PATH/Contents/Info.plist")"
  if [[ "$BUNDLE_IDENTIFIER" != "$IDENTIFIER" ]]; then
    # Bundled XPC lookup and code identity serve different purposes. Preserve
    # the old cryptographic identity while versioning the service lookup name.
    # rcodesign's bundle pass derives its ID from Info.plist, so sign only the
    # main Mach-O again with the same Info/resource special slots and old ID.
    EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$CODE_PATH/Contents/Info.plist")"
    "$SIGNER" sign --config-file /dev/null --timestamp-url none \
      --p12-file "$ENCRYPTED_P12" --p12-password-file "$PASSWORD_FILE" \
      --binary-identifier "$IDENTIFIER" --code-requirements-file "$COMPILED_REQUIREMENT" \
      --info-plist-file "$CODE_PATH/Contents/Info.plist" \
      --code-resources-file "$CODE_PATH/Contents/_CodeSignature/CodeResources" \
      "$CODE_PATH/Contents/MacOS/$EXECUTABLE"
  fi
fi
codesign --verify --strict --requirement "=$REQUIREMENT" "$CODE_PATH"
