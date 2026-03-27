#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Build OpenSSL + SQLCipher as static libraries for a single iOS target.
#
# Usage:
#   ./scripts/build-ios-target.sh <target>
#
# Targets:
#   device-arm64       - arm64 for physical iOS devices
#   simulator-arm64    - arm64 for iOS Simulator (Apple Silicon)
#   simulator-x86_64   - x86_64 for iOS Simulator (Intel)
#
# Environment variables (required):
#   SQLCIPHER_VERSION  - e.g. 4.14.0
#   OPENSSL_VERSION    - e.g. 3.4.1
#   IOS_MIN_VERSION    - e.g. 15.6
#
# Output: out/ios/<target>/{lib,include}/
# =============================================================================

TARGET="${1:?Usage: $0 <target>  (device-arm64 | simulator-arm64 | simulator-x86_64)}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
OUT_DIR="${ROOT_DIR}/out/ios/${TARGET}"
SRC_DIR="${ROOT_DIR}/.build-src"
BUILD_DIR="${ROOT_DIR}/.build-tmp/ios-${TARGET}"

IOS_MIN_VERSION="${IOS_MIN_VERSION:-15.6}"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

# Map target to SDK, arch, and OpenSSL target.
case "${TARGET}" in
  device-arm64)
    SDK="iphoneos"
    ARCH="arm64"
    OPENSSL_TARGET="ios64-xcrun"
    HOST_TRIPLE="aarch64-apple-darwin"
    MIN_VERSION_FLAG="-miphoneos-version-min=${IOS_MIN_VERSION}"
    ;;
  simulator-arm64)
    SDK="iphonesimulator"
    ARCH="arm64"
    OPENSSL_TARGET="iossimulator-xcrun"
    HOST_TRIPLE="aarch64-apple-darwin"
    MIN_VERSION_FLAG="-mios-simulator-version-min=${IOS_MIN_VERSION}"
    ;;
  simulator-x86_64)
    SDK="iphonesimulator"
    ARCH="x86_64"
    OPENSSL_TARGET="iossimulator-xcrun"
    HOST_TRIPLE="x86_64-apple-darwin"
    MIN_VERSION_FLAG="-mios-simulator-version-min=${IOS_MIN_VERSION}"
    ;;
  *)
    echo "Unknown target: ${TARGET}" >&2
    exit 1
    ;;
esac

SDK_PATH="$(xcrun --sdk "${SDK}" --show-sdk-path)"

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
echo "==> Building OpenSSL ${OPENSSL_VERSION} for iOS ${TARGET}..."

mkdir -p "${BUILD_DIR}"
rm -rf "${BUILD_DIR}/openssl"
cp -a "${SRC_DIR}/openssl-${OPENSSL_VERSION}" "${BUILD_DIR}/openssl"
cd "${BUILD_DIR}/openssl"

./Configure "${OPENSSL_TARGET}" \
  -arch "${ARCH}" \
  --prefix="${OUT_DIR}" \
  no-shared no-tests no-ui-console no-engine no-async \
  "${MIN_VERSION_FLAG}" \
  2>&1 | tail -3

make -j"${JOBS}" build_libs 2>&1 | tail -3
make install_dev 2>&1 | tail -3

# --- Build SQLCipher ---
echo "==> Building SQLCipher ${SQLCIPHER_VERSION} for iOS ${TARGET}..."

rm -rf "${BUILD_DIR}/sqlcipher"
cp -a "${SRC_DIR}/sqlcipher-${SQLCIPHER_VERSION}" "${BUILD_DIR}/sqlcipher"
cd "${BUILD_DIR}/sqlcipher"

CC="$(xcrun --sdk "${SDK}" -f clang)" \
AR="$(xcrun --sdk "${SDK}" -f ar)" \
RANLIB="$(xcrun --sdk "${SDK}" -f ranlib)" \
./configure \
  --host="${HOST_TRIPLE}" \
  --prefix="${OUT_DIR}" \
  --disable-shared \
  --with-tempstore=yes \
  --disable-tcl \
  CFLAGS="-arch ${ARCH} \
          -isysroot ${SDK_PATH} \
          ${MIN_VERSION_FLAG} \
          -DSQLITE_HAS_CODEC \
          -DSQLCIPHER_CRYPTO_OPENSSL \
          -DSQLITE_TEMP_STORE=2 \
          -DSQLITE_EXTRA_INIT=sqlcipher_extra_init \
          -DSQLITE_EXTRA_SHUTDOWN=sqlcipher_extra_shutdown \
          -I${OUT_DIR}/include" \
  LDFLAGS="-arch ${ARCH} \
           -isysroot ${SDK_PATH} \
           ${MIN_VERSION_FLAG} \
           -L${OUT_DIR}/lib -lcrypto" \
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
