#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_DIR="$(cd "$PROJECT_DIR/.." && pwd)"
OUTPUT_DIR="${1:-$WORKSPACE_DIR/outputs}"
APP_DIR="$PROJECT_DIR/build/Lantern VNC.app"
case "$OUTPUT_DIR" in
  /*) ;;
  *) echo 'Pass an absolute output directory.' >&2; exit 1 ;;
esac
mkdir -p "$OUTPUT_DIR" "$WORKSPACE_DIR/work"
STAGING_DIR="$(mktemp -d "$WORKSPACE_DIR/work/lantern-package.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT

for source_item in App native scripts tests vendor licenses docs .github README.md LICENSE THIRD_PARTY_NOTICES.md CONTRIBUTING.md CODE_OF_CONDUCT.md SECURITY.md CHANGELOG.md .gitignore; do
  if [[ ! -e "$PROJECT_DIR/$source_item" ]]; then
    echo "Missing source item: $source_item" >&2
    exit 1
  fi
done
if [[ ! -f "$PROJECT_DIR/App/AppIcon.icns" ]]; then
  xcrun swift -module-cache-path "$PROJECT_DIR/build/module-cache" "$PROJECT_DIR/scripts/make-icon.swift"
fi
APP_OUTPUT="$APP_DIR" "$PROJECT_DIR/scripts/build-app.sh"

mkdir -p "$APP_DIR/Contents/Resources/Licenses"
cp "$PROJECT_DIR/README.md" "$APP_DIR/Contents/Resources/README.md"
cp "$PROJECT_DIR/THIRD_PARTY_NOTICES.md" "$APP_DIR/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp "$PROJECT_DIR/LICENSE" "$APP_DIR/Contents/Resources/Licenses/Lantern-VNC-GPL-2.0.txt"
ditto --norsrc --noextattr "$PROJECT_DIR/licenses" "$APP_DIR/Contents/Resources/Licenses"
codesign --force --sign - --identifier local.lantern.vnc "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
if [[ "$(lipo -archs "$APP_DIR/Contents/MacOS/LanternVNC")" != arm64 ]]; then
  echo 'Unexpected app architecture; this package must be arm64.' >&2
  exit 1
fi

APP_STAGE="$STAGING_DIR/Lantern VNC"
SOURCE_STAGE="$STAGING_DIR/Lantern-VNC-source"
mkdir -p "$APP_STAGE"
ditto "$APP_DIR" "$APP_STAGE/Lantern VNC.app"
cp "$PROJECT_DIR/README.md" "$APP_STAGE/README.md"
cp "$PROJECT_DIR/LICENSE" "$APP_STAGE/LICENSE"
cp "$PROJECT_DIR/THIRD_PARTY_NOTICES.md" "$APP_STAGE/THIRD_PARTY_NOTICES.md"
ditto --norsrc --noextattr "$PROJECT_DIR/licenses" "$APP_STAGE/licenses"

# Copy complete vendor trees along with app/build sources; exclude generated
# build directories, VCS state, caches, and compiled object/library outputs.
python3 - "$PROJECT_DIR" "$SOURCE_STAGE" <<'PY'
from pathlib import Path
import shutil
import sys

project, stage = map(Path, sys.argv[1:])
items = ('App', 'native', 'scripts', 'tests', 'vendor', 'licenses', 'docs', '.github',
         'README.md', 'LICENSE', 'THIRD_PARTY_NOTICES.md', 'CONTRIBUTING.md',
         'CODE_OF_CONDUCT.md', 'SECURITY.md', 'CHANGELOG.md', '.gitignore')
excluded = {'.git', '.DS_Store', '__pycache__', '.pytest_cache',
            'build', 'node_modules', '.cache'}
compiled = {'.o', '.a', '.dylib', '.so', '.pyc', '.pyo'}
def ignore(path, names):
    return [name for name in names
            if name in excluded or Path(name).suffix in compiled]
stage.mkdir(parents=True)
for name in items:
    source, destination = project / name, stage / name
    if source.is_dir():
        shutil.copytree(source, destination, ignore=ignore, symlinks=True)
    else:
        shutil.copy2(source, destination)
assert (stage / 'vendor/libvncserver/COPYING').is_file()
assert (stage / 'vendor/libjpeg-turbo/README.ijg').is_file()
assert (stage / 'vendor/libjpeg-turbo/CMakeLists.txt').is_file()
assert (stage / 'App/DeviceStore.swift').is_file()
assert (stage / 'tests/test_device_store.swift').is_file()
assert not list(stage.rglob('*.a'))
assert not list(stage.rglob('*.o'))
PY

APP_ZIP="$STAGING_DIR/Lantern-VNC-macOS.zip"
SOURCE_ZIP="$STAGING_DIR/Lantern-VNC-source.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP_STAGE" "$APP_ZIP"
ditto -c -k --norsrc --noextattr --keepParent "$SOURCE_STAGE" "$SOURCE_ZIP"

# Replace only this script's named deliverables after both archives succeed.
if [[ -e "$OUTPUT_DIR/Lantern VNC.app" ]]; then
  rm -rf "$OUTPUT_DIR/Lantern VNC.app"
fi
ditto "$APP_DIR" "$OUTPUT_DIR/Lantern VNC.app"
mv -f "$APP_ZIP" "$OUTPUT_DIR/Lantern-VNC-macOS.zip"
mv -f "$SOURCE_ZIP" "$OUTPUT_DIR/Lantern-VNC-source.zip"
cp "$PROJECT_DIR/README.md" "$OUTPUT_DIR/Lantern-VNC-README.md"
codesign --verify --deep --strict "$OUTPUT_DIR/Lantern VNC.app"
printf 'Packaged app: %s\nPackaged source: %s\nStandalone app: %s\n' \
  "$OUTPUT_DIR/Lantern-VNC-macOS.zip" "$OUTPUT_DIR/Lantern-VNC-source.zip" "$OUTPUT_DIR/Lantern VNC.app"
