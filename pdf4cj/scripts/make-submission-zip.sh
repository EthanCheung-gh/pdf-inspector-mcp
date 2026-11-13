#!/usr/bin/env bash
# Build dist/pdf4cj.zip for the Cangjie-TPC project-submission flow.
#
# The archive has a single top-level directory `pdf4cj/` (what the TPC
# application expects) and contains the documents, sources, example, tests,
# scripts and contribution material - but never the downloaded stdx binaries,
# build output, previous archives, VCS metadata or logs.
#
# The script stages the payload in a temporary directory, prunes the excluded
# paths there, and zips the staged tree. It is idempotent: an existing
# dist/pdf4cj.zip is replaced, and re-running on an unchanged tree produces the
# same member list.
#
# Usage: bash scripts/make-submission-zip.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_NAME="pdf4cj"
DIST_DIR="${PROJECT_DIR}/dist"
ZIP_PATH="${DIST_DIR}/${PROJECT_NAME}.zip"

# Entries that must exist in the submission; a missing one is a hard error, not
# a silently thinner archive.
REQUIRED_ENTRIES=(
    "README.md"
    "README.OpenSource"
    "CHANGELOG.md"
    "LICENSE"
    "cjpm.toml"
    "doc"
    "src"
    "example"
    "tests"
    "scripts"
    "contrib"
)

# Optional entries: included when present, skipped otherwise. `.gitignore` and
# `.gitattributes` ship with the archive so the reviewer sees the same
# line-ending hygiene (binary fixtures) and build-output exclusions as the repo.
# `cjpm.lock` is deliberately absent: the module has no dependencies besides
# std/stdx, so the lock is always an empty stub and is git-ignored.
OPTIONAL_ENTRIES=(
    ".gitattributes"
    ".gitignore"
)

for entry in "${REQUIRED_ENTRIES[@]}"; do
    if [ ! -e "${PROJECT_DIR}/${entry}" ]; then
        echo "error: required entry '${entry}' is missing from ${PROJECT_DIR}" >&2
        exit 1
    fi
done

if ! command -v zip >/dev/null 2>&1; then
    echo "error: 'zip' is not installed; install it (apt install zip / brew install zip)" >&2
    exit 1
fi

mkdir -p "${DIST_DIR}"
rm -f "${ZIP_PATH}"

STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pdf4cj-submission.XXXXXX")"
cleanup() {
    rm -rf "${STAGE_DIR}"
}
trap cleanup EXIT

STAGED_ROOT="${STAGE_DIR}/${PROJECT_NAME}"
mkdir -p "${STAGED_ROOT}"

for entry in "${REQUIRED_ENTRIES[@]}"; do
    cp -R "${PROJECT_DIR}/${entry}" "${STAGED_ROOT}/${entry}"
done
for entry in "${OPTIONAL_ENTRIES[@]}"; do
    if [ -e "${PROJECT_DIR}/${entry}" ]; then
        cp -R "${PROJECT_DIR}/${entry}" "${STAGED_ROOT}/${entry}"
    fi
done

# Prune anything that must not ship. `target` and `stdx` can appear at any
# depth (the example is its own cjpm module with its own target/), and the
# Python fixture generator leaves `__pycache__` behind the first time it runs.
find "${STAGED_ROOT}" -type d -name "target" -prune -exec rm -rf {} +
find "${STAGED_ROOT}" -type d -name "stdx" -prune -exec rm -rf {} +
find "${STAGED_ROOT}" -type d -name "dist" -prune -exec rm -rf {} +
find "${STAGED_ROOT}" -type d -name ".git" -prune -exec rm -rf {} +
find "${STAGED_ROOT}" -type d -name ".cache" -prune -exec rm -rf {} +
find "${STAGED_ROOT}" -type d -name "build-script-cache" -prune -exec rm -rf {} +
find "${STAGED_ROOT}" -type d -name "__pycache__" -prune -exec rm -rf {} +
find "${STAGED_ROOT}" -type f -name "*.log" -delete
find "${STAGED_ROOT}" -type f -name "*.py[cod]" -delete
# The dependency-free lock file is git-ignored, so it must not reach the archive
# either - at the module root or beside the example module.
find "${STAGED_ROOT}" -type f -name "cjpm.lock" -delete

# -X drops extra file attributes (uid/gid, resource forks) so the archive is
# reproducible across machines.
(
    cd "${STAGE_DIR}"
    zip -q -r -X "${ZIP_PATH}" "${PROJECT_NAME}"
)

SIZE_BYTES="$(wc -c < "${ZIP_PATH}" | tr -d ' ')"
SIZE_HUMAN="$(du -h "${ZIP_PATH}" | cut -f1)"

echo "archive: ${ZIP_PATH}"
echo "size:    ${SIZE_BYTES} bytes (${SIZE_HUMAN})"
echo "members: $(unzip -l "${ZIP_PATH}" | tail -1 | awk '{print $2}') files"
