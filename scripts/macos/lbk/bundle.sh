#!/usr/bin/env bash
# Assemble, verify and pack the macOS release bundle from build/osx-release.
# Usage: scripts/macos/lbk/bundle.sh <version> [arch] [out-dir]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
VERSION="${1:?version required}"
ARCH="${2:-$(uname -m)}"
OUT_DIR="${3:-${REPO_ROOT}/build/lbk-dist}"
MAX_MINOS="${LBK_MAX_MINOS:-13.3}"
BUILD_DIR="${REPO_ROOT}/build/osx-release"
NAME="millennium-${VERSION}-darwin-${ARCH}"
STAGE="${OUT_DIR}/${NAME}"
TARBALL="${NAME}.tar.gz"

BINARIES=(
    steam_osx
    libmillennium_bootstrap.dylib
    libmillennium.dylib
    libmillennium_hhx64.dylib
    libmillennium_child_hook.dylib
    libmillennium_luavm_x86
)

# LBK_SIGN_IDENTITY unset: ad-hoc signature (local builds). Set: Developer ID + hardened runtime + timestamp.
SIGN_IDENTITY="${LBK_SIGN_IDENTITY:-}"
SIGN_KEYCHAIN="${LBK_SIGN_KEYCHAIN:-}"
LUAVM_ENTITLEMENTS="${REPO_ROOT}/scripts/macos/lbk/luavm.entitlements"

fail() { echo "[lbk] ERROR: $*" >&2; exit 1; }

sign_binary() {
    local f="$1"
    if [ -z "${SIGN_IDENTITY}" ]; then
        codesign -f -s - "${f}"
        return
    fi
    local args=(--force --sign "${SIGN_IDENTITY}" --timestamp --options runtime)
    [ -n "${SIGN_KEYCHAIN}" ] && args+=(--keychain "${SIGN_KEYCHAIN}")
    # LuaJIT maps writable+executable code without MAP_JIT; Lua plugins may load native modules.
    [ "$(basename "${f}")" = "libmillennium_luavm_x86" ] && args+=(--entitlements "${LUAVM_ENTITLEMENTS}")
    codesign "${args[@]}" "${f}"
}

rm -rf "${STAGE}" "${OUT_DIR:?}/${TARBALL}" "${OUT_DIR}/${TARBALL}.sha256"
mkdir -p "${STAGE}/runtime/millennium-assets/loader/chunks" "${STAGE}/app"

for bin in "${BINARIES[@]}"; do
    src="${BUILD_DIR}/${bin}"
    [ -f "${src}" ] || src="$(find "${BUILD_DIR}" -type f -name "${bin}" -not -path '*/CMakeFiles/*' -print -quit)"
    [ -n "${src}" ] && [ -f "${src}" ] || fail "missing build artifact ${bin}"
    install -m 0755 "${src}" "${STAGE}/runtime/${bin}"
    # Nothing loads via @rpath, so build-machine LC_RPATH entries (CMake adds the SDK lib dir to hhx64) are dropped.
    otool -l "${STAGE}/runtime/${bin}" | awk '/cmd LC_RPATH/ { getline; getline; print $2 }' | sort -u \
        | while IFS= read -r rpath; do
            install_name_tool -delete_rpath "${rpath}" "${STAGE}/runtime/${bin}" 2>/dev/null
        done
done

LOADER_DIR="${REPO_ROOT}/src/typescript/sdk/build"
install -m 0644 "${LOADER_DIR}/millennium.js" "${STAGE}/runtime/millennium-assets/loader/millennium.js"
chunks=("${LOADER_DIR}"/chunks/chunk-*.js)
[ -e "${chunks[0]}" ] || fail "no loader chunks in ${LOADER_DIR}/chunks"
install -m 0644 "${chunks[@]}" "${STAGE}/runtime/millennium-assets/loader/chunks/"
install -m 0644 "${REPO_ROOT}/src/typescript/.frontend.bin" "${STAGE}/runtime/millennium-assets/millennium-frontend.js"

install -m 0644 "${REPO_ROOT}/src/bootstrap/macos/Info.plist.xml" "${STAGE}/app/Info.plist.xml"
# Below the binaries' minos, Finder would launch the wrapper and dyld would kill it instead of showing "requires a newer macOS".
plutil -replace LSMinimumSystemVersion -string "${MAX_MINOS}" "${STAGE}/app/Info.plist.xml"
plutil -lint "${STAGE}/app/Info.plist.xml" >/dev/null || fail "invalid app/Info.plist.xml"
install -m 0644 "${REPO_ROOT}/src/bootstrap/macos/AppIcon.icns" "${STAGE}/app/AppIcon.icns"
install -m 0755 "${REPO_ROOT}/scripts/macos/install_macos.sh" "${STAGE}/install_macos.sh"
install -m 0644 "${REPO_ROOT}/LICENSE.md" "${STAGE}/LICENSE.md"
printf "%s\n" "${VERSION}" > "${STAGE}/VERSION"

write_notice() {
    local title="$1" file="$2"
    [ -f "${file}" ] || fail "missing license file ${file}"
    printf '\n## %s\n\n```\n' "${title}"
    cat "${file}"
    printf '\n```\n'
}
DEPS_SRC="${BUILD_DIR}/_deps"
OPENSSL_SRC="$(find "${LBK_DEPS_DIR:-${REPO_ROOT}/build/lbk-deps/${ARCH}}/src" -maxdepth 1 -type d -name 'openssl-*' | head -1)"
{
    printf '# Third-party notices\n\nThe binaries in runtime/ statically include the following components.\n'
    write_notice "OpenSSL $(basename "${OPENSSL_SRC}" | sed 's/^openssl-//') (Apache-2.0)" "${OPENSSL_SRC}/LICENSE.txt"
    write_notice "curl (curl license)" "${DEPS_SRC}/curl-src/COPYING"
    write_notice "zlib-ng (Zlib)" "${DEPS_SRC}/zlib-src/LICENSE.md"
    write_notice "minizip-ng (Zlib)" "${DEPS_SRC}/minizip_ng-src/LICENSE"
    write_notice "LuaJIT (MIT)" "${REPO_ROOT}/thirdparty/forks/luajit/COPYRIGHT"
    write_notice "nlohmann/json (MIT)" "${DEPS_SRC}/nlohmann_json-src/LICENSE.MIT"
    write_notice "RE2 (BSD-3-Clause)" "${DEPS_SRC}/re2-src/LICENSE"
    snare_notice="$(mktemp)"
    awk 'NR==1, /\*\//' "${REPO_ROOT}/thirdparty/libsnare.h" > "${snare_notice}"
    write_notice "libsnare (BSD-2-Clause)" "${snare_notice}"
    rm -f "${snare_notice}"
    printf '\n## Rust crates linked into libmillennium_hhx64.dylib\n\n'
    cargo metadata --format-version 1 --locked \
        --manifest-path "${REPO_ROOT}/src/instrumentation/loopback/Cargo.toml" \
        --filter-platform "$( [ "${ARCH}" = arm64 ] && echo aarch64 || echo x86_64 )-apple-darwin" \
        | python3 -c '
import json, sys
m = json.load(sys.stdin)
pk = {p["id"]: p for p in m["packages"]}
nodes = {n["id"]: n for n in m["resolve"]["nodes"]}
root = m["resolve"]["root"]
seen, stack = set(), [root]
while stack:
    cur = stack.pop()
    for d in nodes[cur]["deps"]:
        if any(k["kind"] in (None, "normal") for k in d["dep_kinds"]) and d["pkg"] not in seen:
            seen.add(d["pkg"]); stack.append(d["pkg"])
for p in sorted((pk[i] for i in seen), key=lambda p: p["name"]):
    print("- {} {} ({})".format(p["name"], p["version"], p.get("license") or "see crate"))
'
} > "${STAGE}/THIRD_PARTY_NOTICES.md"

echo "[lbk] verifying Mach-O files"
errors=0
for bin in "${BINARIES[@]}"; do
    f="${STAGE}/runtime/${bin}"
    sign_binary "${f}" || { echo "codesign failed: ${bin}"; errors=1; }

    # child_hook is deliberately universal (x86_64 arm64 arm64e) to load into every Steam Helper.
    archs="$(lipo -archs "${f}")"
    case " ${archs} " in
        *" ${ARCH} "*) ;;
        *) echo "${bin}: archs '${archs}' lack '${ARCH}'"; errors=1 ;;
    esac

    id="$(otool -D "${f}" | tail -n +2)"
    deps="$(otool -L "${f}" | tail -n +2 | awk '{print $1}' | grep -vxF "${id:-<none>}" || true)"
    echo "  ${bin} [${archs}]${id:+ id=${id}}:"
    while IFS= read -r dep; do
        [ -n "${dep}" ] || continue
        echo "    ${dep}"
        case "${dep}" in
            /usr/lib/*|/System/Library/*|@loader_path/*|@executable_path/*) ;;
            *) echo "    ^ not a system library"; errors=1 ;;
        esac
    done <<< "${deps}"

    if otool -l "${f}" | grep -A2 LC_RPATH | grep -E '^ +path ' ; then
        echo "${bin}: unexpected LC_RPATH"; errors=1
    fi

    minos="$(vtool -show-build "${f}" | awk '/minos/ {print $2}' | sort -V | tail -1)"
    echo "    minos ${minos}"
    if [ -z "${minos}" ] || [ "$(printf '%s\n%s\n' "${minos}" "${MAX_MINOS}" | sort -V | tail -1)" != "${MAX_MINOS}" ]; then
        echo "${bin}: minos ${minos} is newer than ${MAX_MINOS}"; errors=1
    fi

    codesign --verify --strict --verbose=2 "${f}" || { echo "${bin}: signature invalid"; errors=1; }
    if [ -n "${SIGN_IDENTITY}" ]; then
        info="$(codesign -dv --verbose=4 "${f}" 2>&1)"
        echo "${info}" | grep -E '^(Authority|TeamIdentifier|CodeDirectory|Timestamp)' | sed 's/^/    /'
        echo "${info}" | grep -q 'flags=.*runtime' || { echo "${bin}: hardened runtime flag missing"; errors=1; }
        echo "${info}" | grep -q '^Authority=Developer ID Application' || { echo "${bin}: not Developer ID signed"; errors=1; }
        echo "${info}" | grep -q '^Timestamp=' || { echo "${bin}: no secure timestamp"; errors=1; }
    fi
done
if grep -rlE '/opt/homebrew|/usr/local/opt|/usr/local/Cellar' "${STAGE}/runtime" ; then
    echo "Homebrew path strings found in runtime files"; errors=1
fi
[ "${errors}" -eq 0 ] || fail "bundle verification failed"

for f in install_macos.sh LICENSE.md THIRD_PARTY_NOTICES.md VERSION app/Info.plist.xml app/AppIcon.icns \
         runtime/millennium-assets/loader/millennium.js runtime/millennium-assets/millennium-frontend.js; do
    [ -s "${STAGE}/${f}" ] || fail "missing ${f}"
done

COMMIT="$(git -C "${REPO_ROOT}" rev-parse HEAD)"
(
    cd "${STAGE}"
    python3 - "${VERSION}" "${COMMIT}" "${ARCH}" "$(grep -v '^#' "${REPO_ROOT}/scripts/version" | tr -d '[:space:]')" <<'PY'
import hashlib, json, os, sys
version, commit, arch, upstream = sys.argv[1:5]
files = {}
for root, _, names in os.walk("."):
    for n in sorted(names):
        p = os.path.relpath(os.path.join(root, n), ".")
        if p == "manifest.json":
            continue
        with open(p, "rb") as fh:
            files[p] = hashlib.sha256(fh.read()).hexdigest()
manifest = {
    "version": version,
    "upstreamVersion": upstream,
    "commit": commit,
    "arch": arch,
    "platform": "darwin",
    "files": dict(sorted(files.items())),
}
with open("manifest.json", "w") as fh:
    json.dump(manifest, fh, indent=2)
    fh.write("\n")
PY
)

COPYFILE_DISABLE=1 tar -C "${OUT_DIR}" -czf "${OUT_DIR}/${TARBALL}" "${NAME}"
(cd "${OUT_DIR}" && shasum -a 256 "${TARBALL}" > "${TARBALL}.sha256")

echo "[lbk] dry-run install from the bundle"
scratch="$(mktemp -d)"
bash "${STAGE}/install_macos.sh" --from-bundle "${STAGE}" --dry-run \
    --app-bundle "${scratch}/Steam Millennium.app" --runtime-install-root "${scratch}/runtime" \
    | tee "${scratch}/dry-run.log"
grep -q "runtime/${VERSION}" "${scratch}/dry-run.log" || fail "dry run did not use bundle version"
rm -rf "${scratch}"

ls -l "${OUT_DIR}/${TARBALL}"
cat "${OUT_DIR}/${TARBALL}.sha256"
