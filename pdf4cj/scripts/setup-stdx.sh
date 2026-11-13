#!/usr/bin/env bash
# Fetch and unpack the cangjie-stdx binaries pdf4cj needs for zlib and base64.
#
# Idempotent: when the unpacked tree is already present the download is skipped.
#
# pdf4cj is pure Cangjie and only depends on std plus stdx (stdx.compress.zlib,
# stdx.encoding.base64). cjpm finds those binary packages through
# ${CANGJIE_STDX_PATH}, which is set by this script; see cjpm.toml.
#
# This script covers the Linux x86_64 layout only. On other hosts, fetch the
# matching release from
# https://gitcode.com/Cangjie/cangjie-stdx-bin/releases/tag/v1.0.0.1
# (cangjie-stdx-linux-aarch64-*, cangjie-stdx-mac-*), unpack it under
# pdf4cj/stdx/, and point CANGJIE_STDX_PATH at the unpacked
# cangjie-stdx-<platform>-1.0.0.1 directory. The ${CANGJIE_STDX_PATH} entries in
# cjpm.toml already name the per-platform subdirectories
# (linux_x86_64_llvm, linux_aarch64_llvm, darwin_x86_64_llvm,
# darwin_aarch64_llvm, windows_x86_64_llvm).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
STDX_DIR="${PROJECT_DIR}/stdx"

STDX_VERSION="1.0.0.1"
STDX_NAME="cangjie-stdx-linux-x64-${STDX_VERSION}"
STDX_URL="https://gitcode.com/Cangjie/cangjie-stdx-bin/releases/download/v${STDX_VERSION}/${STDX_NAME}.zip"
STDX_ROOT="${STDX_DIR}/${STDX_NAME}"
STDX_MARKER="${STDX_ROOT}/linux_x86_64_llvm/dynamic/stdx"

if [ ! -d "${STDX_MARKER}" ]; then
    echo "Downloading ${STDX_URL}"
    mkdir -p "${STDX_DIR}"
    if ! curl -fL --retry 3 --retry-delay 2 -o "${STDX_DIR}/${STDX_NAME}.zip" "${STDX_URL}"; then
        echo "error: failed to download ${STDX_URL}" >&2
        exit 1
    fi

    echo "Unpacking into ${STDX_ROOT}"
    if ! unzip -q -o "${STDX_DIR}/${STDX_NAME}.zip" -d "${STDX_ROOT}"; then
        echo "error: failed to unzip ${STDX_DIR}/${STDX_NAME}.zip" >&2
        exit 1
    fi

    rm -f "${STDX_DIR}/${STDX_NAME}.zip"

    if [ ! -d "${STDX_MARKER}" ]; then
        echo "error: ${STDX_MARKER} not found after unpacking" >&2
        exit 1
    fi
fi

echo "cangjie-stdx ${STDX_VERSION} ready at ${STDX_ROOT}"
echo
echo "Add it to your shell before building:"
echo "export CANGJIE_STDX_PATH=\"\$(cd \"\$(dirname \"\$0\")/../stdx/${STDX_NAME}\" && pwd)\""
