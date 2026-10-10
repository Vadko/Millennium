#!/usr/bin/env bash
# Self-contained macOS Release build: static OpenSSL, no Homebrew dylibs in the output.
# Usage: scripts/macos/lbk/build.sh [arm64|x86_64]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
ARCH="${1:-$(uname -m)}"
# libc++ floating-point std::format (to_chars) needs 13.3.
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.3}"
OPENSSL_VERSION="3.5.9"
OPENSSL_SHA256="603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a"
DEPS_DIR="${LBK_DEPS_DIR:-${REPO_ROOT}/build/lbk-deps/${ARCH}}"
OPENSSL_PREFIX="${DEPS_DIR}/openssl-${OPENSSL_VERSION}"
BUILD_DIR="${REPO_ROOT}/build/osx-release"

export MACOSX_DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET}"
# strip=true also strips proc-macro dylibs, and recent rustc then cannot load them (E0463 rustversion).
export CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_STRIP=false

case "${ARCH}" in
    arm64) OPENSSL_TARGET="darwin64-arm64-cc"; RUST_TARGET="aarch64-apple-darwin" ;;
    x86_64) OPENSSL_TARGET="darwin64-x86_64-cc"; RUST_TARGET="x86_64-apple-darwin" ;;
    *) echo "unsupported arch: ${ARCH}" >&2; exit 1 ;;
esac

build_openssl() {
    if [ -f "${OPENSSL_PREFIX}/lib/libcrypto.a" ] && [ -f "${OPENSSL_PREFIX}/lib/libssl.a" ]; then
        echo "[lbk] OpenSSL ${OPENSSL_VERSION} already built at ${OPENSSL_PREFIX}"
        return
    fi

    local work="${DEPS_DIR}/src"
    local tarball="${work}/openssl-${OPENSSL_VERSION}.tar.gz"
    mkdir -p "${work}"
    if [ ! -f "${tarball}" ]; then
        curl -fsSL -o "${tarball}" \
            "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz"
    fi
    echo "${OPENSSL_SHA256}  ${tarball}" | shasum -a 256 -c -

    rm -rf "${work}/openssl-${OPENSSL_VERSION}"
    tar -xzf "${tarball}" -C "${work}"
    (
        cd "${work}/openssl-${OPENSSL_VERSION}"
        # openssldir only sets compiled-in defaults; curl gets an explicit CA bundle below.
        ./Configure "${OPENSSL_TARGET}" no-shared no-tests no-docs no-module \
            "--prefix=${OPENSSL_PREFIX}" --libdir=lib --openssldir=/private/etc/ssl \
            "-mmacosx-version-min=${DEPLOYMENT_TARGET}"
        make -j"$(sysctl -n hw.ncpu)" build_libs
        make install_dev
    )
}

build_openssl

# minizip-ng asks pkg-config for openssl first; hide every Homebrew .pc so it gets the static build.
export PKG_CONFIG_LIBDIR="${OPENSSL_PREFIX}/lib/pkgconfig"
unset PKG_CONFIG_PATH

if [ "${ARCH}" != "$(uname -m)" ]; then
    rustup target add "${RUST_TARGET}"
fi

# Keep pkg-config from resolving Homebrew's OpenSSL dylibs.
export PKG_CONFIG_PATH="${OPENSSL_PREFIX}/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="${OPENSSL_PREFIX}/lib/pkgconfig"

rm -f "${BUILD_DIR}/CMakeCache.txt"
cmake --preset=osx-release \
    -DMILLENNIUM_BUILD_TESTS=OFF \
    -DMILLENNIUM_RUN_TESTS_ON_BUILD=OFF \
    -DMILLENNIUM_BUILD_TO_STEAM_PATH=OFF \
    -DCMAKE_OSX_ARCHITECTURES="${ARCH}" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET}" \
    -DRust_CARGO_TARGET="${RUST_TARGET}" \
    -DOPENSSL_ROOT_DIR="${OPENSSL_PREFIX}" \
    -DOPENSSL_USE_STATIC_LIBS=ON \
    -DMILLENNIUM_MACOS_SELF_CONTAINED=ON

cmake --build "${BUILD_DIR}" --config Release -- -j"$(sysctl -n hw.ncpu)"
