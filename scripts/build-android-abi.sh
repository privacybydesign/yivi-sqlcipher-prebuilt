#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Build OpenSSL + SQLCipher as static libraries for a single Android ABI.
#
# Usage:
#   ./scripts/build-android-abi.sh <abi>
#
# Environment variables (required):
#   SQLCIPHER_VERSION  - e.g. 4.14.0
#   OPENSSL_VERSION    - e.g. 3.4.1
#   NDK_VERSION        - e.g. 28.2.13676358
#   MIN_API            - e.g. 26
#   ANDROID_HOME       - path to Android SDK
#
# Output: out/android/<abi>/{lib,include}/
# =============================================================================

ABI="${1:?Usage: $0 <abi>  (arm64-v8a | armeabi-v7a | x86_64)}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
OUT_DIR="${ROOT_DIR}/out/android/${ABI}"
SRC_DIR="${ROOT_DIR}/.build-src"
BUILD_DIR="${ROOT_DIR}/.build-tmp/${ABI}"

NDK_HOME="${ANDROID_HOME}/ndk/${NDK_VERSION}"

# Detect host OS for NDK toolchain.
case "$(uname -s)" in
  Darwin*)  HOST_OS="darwin-x86_64" ;;
  Linux*)   HOST_OS="linux-x86_64" ;;
  *)        echo "Unsupported host OS" >&2; exit 1 ;;
esac
TOOLCHAIN="${NDK_HOME}/toolchains/llvm/prebuilt/${HOST_OS}"

get_triple() {
  case "$1" in
    arm64-v8a)   echo "aarch64-linux-android" ;;
    armeabi-v7a) echo "armv7a-linux-androideabi" ;;
    x86_64)      echo "x86_64-linux-android" ;;
  esac
}

get_openssl_target() {
  case "$1" in
    arm64-v8a)   echo "android-arm64" ;;
    armeabi-v7a) echo "android-arm" ;;
    x86_64)      echo "android-x86_64" ;;
  esac
}

get_host_triple() {
  case "$1" in
    arm64-v8a)   echo "aarch64-linux-android" ;;
    armeabi-v7a) echo "arm-linux-androideabi" ;;
    x86_64)      echo "x86_64-linux-android" ;;
  esac
}

JOBS="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"

# --- Download sources ---
mkdir -p "${SRC_DIR}"

if [ ! -d "${SRC_DIR}/openssl-${OPENSSL_VERSION}" ]; then
  echo "==> Downloading OpenSSL ${OPENSSL_VERSION}..."
  curl -sL "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz" \
    | tar -xzf - -C "${SRC_DIR}"
fi

if [ ! -d "${SRC_DIR}/sqlcipher-${SQLCIPHER_VERSION}" ]; then
  echo "==> Downloading SQLCipher ${SQLCIPHER_VERSION}..."
  curl -sL "https://github.com/sqlcipher/sqlcipher/archive/refs/tags/v${SQLCIPHER_VERSION}.tar.gz" \
    | tar -xzf - -C "${SRC_DIR}"
fi

# --- Build OpenSSL ---
echo "==> Building OpenSSL ${OPENSSL_VERSION} for ${ABI}..."

mkdir -p "${BUILD_DIR}"
rm -rf "${BUILD_DIR}/openssl"
cp -a "${SRC_DIR}/openssl-${OPENSSL_VERSION}" "${BUILD_DIR}/openssl"
cd "${BUILD_DIR}/openssl"

export ANDROID_NDK_ROOT="${NDK_HOME}"
export PATH="${TOOLCHAIN}/bin:${PATH}"

./Configure "$(get_openssl_target "${ABI}")" \
  -D__ANDROID_API__="${MIN_API}" \
  --prefix="${OUT_DIR}" \
  no-shared no-tests no-ui-console no-engine no-async \
  2>&1 | tail -3

make -j"${JOBS}" build_libs 2>&1 | tail -3
make install_dev 2>&1 | tail -3

# --- Build SQLCipher ---
echo "==> Building SQLCipher ${SQLCIPHER_VERSION} for ${ABI}..."

TRIPLE="$(get_triple "${ABI}")"
HOST_TRIPLE="$(get_host_triple "${ABI}")"

rm -rf "${BUILD_DIR}/sqlcipher"
cp -a "${SRC_DIR}/sqlcipher-${SQLCIPHER_VERSION}" "${BUILD_DIR}/sqlcipher"
cd "${BUILD_DIR}/sqlcipher"

CC="${TOOLCHAIN}/bin/${TRIPLE}${MIN_API}-clang" \
AR="${TOOLCHAIN}/bin/llvm-ar" \
RANLIB="${TOOLCHAIN}/bin/llvm-ranlib" \
./configure \
  --host="${HOST_TRIPLE}" \
  --prefix="${OUT_DIR}" \
  --disable-shared \
  --with-tempstore=yes \
  --disable-tcl \
  CFLAGS="-DSQLITE_HAS_CODEC \
          -DSQLCIPHER_CRYPTO_OPENSSL \
          -DSQLITE_TEMP_STORE=2 \
          -DSQLITE_EXTRA_INIT=sqlcipher_extra_init \
          -DSQLITE_EXTRA_SHUTDOWN=sqlcipher_extra_shutdown \
          -I${OUT_DIR}/include" \
  LDFLAGS="-L${OUT_DIR}/lib -lcrypto" \
  2>&1 | tail -5

make -j"${JOBS}" libsqlite3.a 2>&1 | tail -3

mkdir -p "${OUT_DIR}/lib" "${OUT_DIR}/include/sqlcipher"
cp libsqlite3.a "${OUT_DIR}/lib/libsqlcipher.a"
cp sqlite3.h "${OUT_DIR}/include/sqlite3.h"
cp sqlite3.h "${OUT_DIR}/include/sqlcipher/sqlite3.h"

# --- Cleanup ---
rm -rf "${BUILD_DIR}"

echo "==> Done: ${OUT_DIR}"
ls -lh "${OUT_DIR}/lib/"
