#!/usr/bin/env bash
# Fetch and unpack the cangjie-stdx binaries CangjieMagic needs.
#
# Idempotent: when the unpacked tree is already present the download is skipped.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LIBS_DIR="${PROJECT_DIR}/libs"

STDX_VERSION="1.0.0.1"
STDX_NAME="cangjie-stdx-linux-x64-${STDX_VERSION}"
STDX_URL="https://gitcode.com/Cangjie/cangjie-stdx-bin/releases/download/v${STDX_VERSION}/${STDX_NAME}.zip"
STDX_ROOT="${LIBS_DIR}/${STDX_NAME}"
STDX_MARKER="${STDX_ROOT}/linux_x86_64_llvm/dynamic/stdx"

if [ -d "${STDX_MARKER}" ]; then
    echo "cangjie-stdx ${STDX_VERSION} already present at ${STDX_ROOT}, skipping."
    exit 0
fi

echo "Downloading ${STDX_URL}"
mkdir -p "${LIBS_DIR}"
if ! curl -fL --retry 3 --retry-delay 2 -o "${LIBS_DIR}/${STDX_NAME}.zip" "${STDX_URL}"; then
    echo "error: failed to download ${STDX_URL}" >&2
    exit 1
fi

echo "Unpacking into ${STDX_ROOT}"
if ! unzip -q -o "${LIBS_DIR}/${STDX_NAME}.zip" -d "${STDX_ROOT}"; then
    echo "error: failed to unzip ${LIBS_DIR}/${STDX_NAME}.zip" >&2
    exit 1
fi

rm -f "${LIBS_DIR}/${STDX_NAME}.zip"

if [ ! -d "${STDX_MARKER}" ]; then
    echo "error: ${STDX_MARKER} not found after unpacking" >&2
    exit 1
fi

echo "cangjie-stdx ${STDX_VERSION} ready at ${STDX_ROOT}"
