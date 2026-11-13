#!/usr/bin/env bash
# Fetch and unpack the cangjie-stdx binaries this project needs.
#
# Two stdx trees are involved:
#
#   1. cangjie/libs/...         - CangjieMagic's bin-dependency (see cjpm.toml);
#   2. ../../pdf4cj/stdx/...    - pdf4cj's stdx, resolved through the
#                                 ${CANGJIE_STDX_PATH} entries in
#                                 pdf4cj/cjpm.toml. pdf4cj is a standalone
#                                 sibling project consumed as a path
#                                 dependency, so its own setup-stdx.sh is
#                                 delegated to below.
#
# Idempotent: when the unpacked tree is already present the download is skipped.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LIBS_DIR="${PROJECT_DIR}/libs"
PDF4CJ_DIR="$(cd "${PROJECT_DIR}/../../pdf4cj" && pwd)"

STDX_VERSION="1.0.0.1"
STDX_NAME="cangjie-stdx-linux-x64-${STDX_VERSION}"
STDX_URL="https://gitcode.com/Cangjie/cangjie-stdx-bin/releases/download/v${STDX_VERSION}/${STDX_NAME}.zip"
STDX_ROOT="${LIBS_DIR}/${STDX_NAME}"
STDX_MARKER="${STDX_ROOT}/linux_x86_64_llvm/dynamic/stdx"

if [ -d "${STDX_MARKER}" ]; then
    echo "cangjie-stdx ${STDX_VERSION} already present at ${STDX_ROOT}, skipping."
else
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
fi

# pdf4cj is a standalone sibling project (../../pdf4cj) consumed as a path
# dependency and keeps its own stdx copy; let its script place and report it so
# both trees stay in sync with one command.
if [ ! -f "${PDF4CJ_DIR}/scripts/setup-stdx.sh" ]; then
    echo "error: ${PDF4CJ_DIR}/scripts/setup-stdx.sh not found" >&2
    exit 1
fi

bash "${PDF4CJ_DIR}/scripts/setup-stdx.sh"

echo
echo "Export the pdf4cj stdx path before building:"
echo "export CANGJIE_STDX_PATH=\"${PDF4CJ_DIR}/stdx/${STDX_NAME}\""
