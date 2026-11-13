#!/usr/bin/env bash
# Run every check the Cangjie port has, in the order a reviewer expects:
#
#   1. pdf4cj cjpm test  - the PDF library this server imports via a path
#                          dependency, tested from ../pdf4cj first;
#   2. cjpm build        - compile the server (and its debug helpers);
#   3. cjpm test         - unit tests + the golden integration tests against the
#                          committed Python baseline in tests/goldens/;
#   4. e2e-smoke.sh      - drive the real stdio server over JSON-RPC.
#
# A green run therefore covers both the library and the MCP layer.
#
# The stdx dependency is fetched on demand, so a clean checkout works without a
# manual setup step. Usage: bash cangjie/scripts/test-all.sh
#
# Environment overrides: CJV, CJ_TOOLCHAIN, CANGJIE_STDX_PATH.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${PROJECT_DIR}/.." && pwd)"
CJV="${CJV:-${HOME}/.cjv/bin/cjv}"
TOOLCHAIN="${CJ_TOOLCHAIN:-lts-1.0.0}"
STDX_DIR="${PROJECT_DIR}/libs/cangjie-stdx-linux-x64-1.0.0.1/linux_x86_64_llvm/dynamic/stdx"
LIB_DIR="${REPO_ROOT}/pdf4cj"
LIB_STDX_DIR="${LIB_DIR}/stdx/cangjie-stdx-linux-x64-1.0.0.1"

# pdf4cj/cjpm.toml resolves stdx through ${CANGJIE_STDX_PATH}; export it here so
# both projects are built against the same unpacked tree.
export CANGJIE_STDX_PATH="${CANGJIE_STDX_PATH:-${LIB_STDX_DIR}}"

STAGE_NAMES=()
STAGE_RESULTS=()

cd "${PROJECT_DIR}"

print_summary() {
    echo
    echo "--------------------------------------------------------------------"
    echo "Summary"
    echo "--------------------------------------------------------------------"
    if [ "${#STAGE_NAMES[@]}" -eq 0 ]; then
        echo "  (no stage ran)"
        return
    fi
    local index
    for index in "${!STAGE_NAMES[@]}"; do
        printf '  %-22s %s\n' "${STAGE_NAMES[${index}]}" "${STAGE_RESULTS[${index}]}"
    done
    echo "--------------------------------------------------------------------"
}

# Run one named stage, recording its duration, and stop the whole script (after
# printing the summary) when it fails. The status has to be captured *inside*
# the else branch: once the `if` compound finishes, `$?` is the status of the
# compound (0 when no branch ran), not of "$@" - which silently turned failures
# into exit 0.
run_stage() {
    local name="$1"
    shift
    echo
    echo "==> ${name}"
    local started=${SECONDS}
    if "$@"; then
        STAGE_NAMES+=("${name}")
        STAGE_RESULTS+=("PASS ($((SECONDS - started))s)")
        return 0
    else
        local status=$?
        STAGE_NAMES+=("${name}")
        STAGE_RESULTS+=("FAIL (exit ${status}, $((SECONDS - started))s)")
        print_summary
        return "${status}"
    fi
}

run_stdx_setup() {
    bash "${SCRIPT_DIR}/setup-stdx.sh"
}

# The path dependency is verified on its own first: its package (`pdf4cj`) is
# what the MCP code imports, and a failure there should not be reported as an
# MCP test failure. The subshell keeps `test-all.sh`'s cwd.
run_library_tests() {
    (
        cd "${LIB_DIR}"
        "${CJV}" run "${TOOLCHAIN}" cjpm test
    )
}

run_build() {
    "${CJV}" run "${TOOLCHAIN}" cjpm build
}

run_tests() {
    "${CJV}" run "${TOOLCHAIN}" cjpm test
}

run_e2e() {
    bash "${SCRIPT_DIR}/e2e-smoke.sh"
}

if [ ! -x "${CJV}" ]; then
    echo "error: ${CJV} is missing; install cjv or set CJV" >&2
    exit 1
fi

if [ ! -d "${STDX_DIR}" ] || [ ! -d "${LIB_STDX_DIR}" ]; then
    run_stage "setup-stdx" run_stdx_setup
fi

run_stage "pdf4cj cjpm test" run_library_tests
run_stage "cjpm build" run_build
run_stage "cjpm test" run_tests
run_stage "e2e-smoke" run_e2e

print_summary
echo
echo "All stages passed."
