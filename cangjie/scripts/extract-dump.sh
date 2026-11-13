#!/usr/bin/env bash
# Dump what the content-stream interpreter extracts for one page.
#
# Usage: bash cangjie/scripts/extract-dump.sh /tmp/pc-text.pdf [page]
#
# Builds/runs the `pdf_inspector_mcp.extractdebug` package with the LTS toolchain
# the CangjieMagic dependency requires (1.2.0 is not compatible). This cjpm
# version forwards program arguments with --run-args (not `--`).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CJV="${CJV:-${HOME}/.cjv/bin/cjv}"
TOOLCHAIN="${CJ_TOOLCHAIN:-lts-1.0.0}"

# pdf4cj (path dependency) resolves stdx through ${CANGJIE_STDX_PATH}.
export CANGJIE_STDX_PATH="${CANGJIE_STDX_PATH:-$(cd "${PROJECT_DIR}/../pdf4cj/stdx/cangjie-stdx-linux-x64-1.0.0.1" && pwd)}"

cd "${PROJECT_DIR}"

if [ "$#" -eq 0 ]; then
    exec "${CJV}" run "${TOOLCHAIN}" cjpm run --name pdf_inspector_mcp.extractdebug
fi

# `--run-args` takes one shell-escaped string for the target program.
RUN_ARGS="$(printf '%q ' "$@")"
exec "${CJV}" run "${TOOLCHAIN}" cjpm run --name pdf_inspector_mcp.extractdebug --run-args "${RUN_ARGS}"
