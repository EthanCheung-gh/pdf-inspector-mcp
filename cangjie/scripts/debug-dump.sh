#!/usr/bin/env bash
# Dump the facts the PDF core exposes for one file.
#
# Usage: bash cangjie/scripts/debug-dump.sh /tmp/pc-text.pdf
#
# Builds/runs the `pdf_inspector_mcp.debug` package with the LTS toolchain the
# CangjieMagic dependency requires (1.2.0 is not compatible). This cjpm version
# forwards program arguments with --run-args (not `--`).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CJV="${CJV:-${HOME}/.cjv/bin/cjv}"
TOOLCHAIN="${CJ_TOOLCHAIN:-lts-1.0.0}"

cd "${PROJECT_DIR}"

if [ "$#" -eq 0 ]; then
    exec "${CJV}" run "${TOOLCHAIN}" cjpm run --name pdf_inspector_mcp.debug
fi

# `--run-args` takes one shell-escaped string for the target program.
RUN_ARGS="$(printf '%q ' "$@")"
exec "${CJV}" run "${TOOLCHAIN}" cjpm run --name pdf_inspector_mcp.debug --run-args "${RUN_ARGS}"
