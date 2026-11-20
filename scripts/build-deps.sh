#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_DIR="$(cd "$PROJECT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"

if [[ -n "${CMAKE_BIN:-}" ]]; then
  cmake_bin="$CMAKE_BIN"
elif command -v cmake >/dev/null 2>&1; then
  cmake_bin="$(command -v cmake)"
elif [[ -x "$WORKSPACE_DIR/work/deps/python/cmake/data/bin/cmake" ]]; then
  cmake_bin="$WORKSPACE_DIR/work/deps/python/cmake/data/bin/cmake"
else
  echo 'CMake 3.16 or later is required to build the native libraries.' >&2
  echo 'Set CMAKE_BIN to its executable or install CMake before building.' >&2
  exit 1
fi

if [[ ! -f "$PROJECT_DIR/vendor/libvncserver/CMakeLists.txt" || ! -f "$PROJECT_DIR/vendor/libjpeg-turbo/CMakeLists.txt" ]]; then
  echo 'Missing vendor sources. Restore vendor/libvncserver and vendor/libjpeg-turbo from the source archive.' >&2
  exit 1
fi

build_jobs="${BUILD_JOBS:-8}"
macos_target="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
build_arch="${BUILD_ARCH:-arm64}"

"$cmake_bin" -S "$PROJECT_DIR/vendor/libjpeg-turbo" -B "$BUILD_DIR/jpeg" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES="$build_arch" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$macos_target" \
  -DENABLE_SHARED=OFF -DENABLE_STATIC=ON \
  -DWITH_TURBOJPEG=OFF -DWITH_TOOLS=OFF -DWITH_TESTS=OFF \
  -DWITH_SIMD=ON -DREQUIRE_SIMD=ON
"$cmake_bin" --build "$BUILD_DIR/jpeg" --target jpeg-static --parallel "$build_jobs"

mkdir -p "$BUILD_DIR/jpeg/include"
cp "$PROJECT_DIR/vendor/libjpeg-turbo/src/jpeglib.h" "$BUILD_DIR/jpeg/include/"
cp "$PROJECT_DIR/vendor/libjpeg-turbo/src/jmorecfg.h" "$BUILD_DIR/jpeg/include/"
cp "$PROJECT_DIR/vendor/libjpeg-turbo/src/jerror.h" "$BUILD_DIR/jpeg/include/"
cp "$BUILD_DIR/jpeg/jconfig.h" "$BUILD_DIR/jpeg/include/"

"$cmake_bin" -S "$PROJECT_DIR/vendor/libvncserver" -B "$BUILD_DIR/vnc" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES="$build_arch" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$macos_target" \
  -DBUILD_SHARED_LIBS=OFF \
  -DJPEG_LIBRARY="$BUILD_DIR/jpeg/libjpeg.a" \
  -DJPEG_INCLUDE_DIR="$BUILD_DIR/jpeg/include" \
  -DWITH_ZLIB=ON -DWITH_JPEG=ON -DWITH_THREADS=ON \
  -DWITH_PNG=OFF -DWITH_LZO=OFF -DWITH_GNUTLS=OFF \
  -DWITH_OPENSSL=OFF -DWITH_GCRYPT=OFF -DWITH_SASL=OFF \
  -DWITH_SYSTEMD=OFF -DWITH_SDL=OFF -DWITH_GTK=OFF \
  -DWITH_QT=OFF -DWITH_XCB=OFF -DWITH_FFMPEG=OFF \
  -DWITH_LIBSSHTUNNEL=OFF -DWITH_WEBSOCKETS=OFF \
  -DWITH_TIGHTVNC_FILETRANSFER=OFF \
  -DWITH_EXAMPLES=OFF -DWITH_TESTS=OFF
"$cmake_bin" --build "$BUILD_DIR/vnc" --target vncclient --parallel "$build_jobs"

echo "Native dependency archives: $BUILD_DIR/vnc/libvncclient.a $BUILD_DIR/jpeg/libjpeg.a"
