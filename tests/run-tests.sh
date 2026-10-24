#!/usr/bin/env bash
#
# run-tests.sh - runs the tests of Prokfinder (bats-core)
#
# Usage:
#   tests/run-tests.sh [--level <levels>] [--update-expected] [-- <bats options>]
#
# Levels (comma-separated; default: unit,cli,module):
#   unit     functions of lib/common.sh                                     seconds, no data
#   cli      command line of main-prokfinder.sh, run-on-cluster --dry-run,   seconds, no data
#            syntax, shellcheck, module headers, catalog
#   module   each module on the fixture of tests/data (small slices of the   minutes, no network
#            reference tables, a few genomes, fake programs in tests/bin)
#   e2e      real runs (setup from the sources, download-wf with CheckM2,     hours, network and the real
#            BUSCO, GTDB-Tk): only when asked for                            databases; on the cluster
#
# The levels unit, cli and module never use the network nor the real reference databases.

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEVELS="unit,cli,module"
UPDATE_EXPECTED=0
BATS_ARGS=()

usage() {
    awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "${BASH_SOURCE[0]}"
    echo "Options:"
    echo "  -l, --level <levels>   levels to run (unit, cli, module, e2e; or all)"
    echo "  --update-expected      rewrite tests/expected/ with the results found (review them with git diff)"
    echo "  -h, --help             show this help"
    echo "  -- <bats options>      passed to bats (e.g., -- --filter 'format_tsv' or -- --jobs 4)"
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -l|--level)
            [[ $# -ge 2 ]] || { echo "ERROR: $1 requires a value. Use $0 -h to see the options." >&2; exit 1; }
            LEVELS="$2"; shift 2 ;;
        --update-expected) UPDATE_EXPECTED=1; shift ;;
        -h|--help)         usage 0 ;;
        --)                shift; BATS_ARGS=("$@"); break ;;
        *)                 echo "ERROR: unknown option '$1'. Use $0 -h to see the options." >&2; exit 1 ;;
    esac
done
[[ "${LEVELS}" != "all" ]] || LEVELS="unit,cli,module,e2e"

if ! command -v bats >/dev/null 2>&1; then
    echo "ERROR: bats was not found in the PATH (install: conda install -c conda-forge bats-core)." >&2
    exit 1
fi

DIRS=()
IFS=',' read -ra LEVEL_LIST <<< "${LEVELS}"
for LEVEL in "${LEVEL_LIST[@]}"; do
    case "${LEVEL}" in
        unit|cli|module|e2e) ;;
        *) echo "ERROR: unknown level '${LEVEL}' (unit, cli, module, e2e or all)." >&2; exit 1 ;;
    esac
    if compgen -G "${TESTS_DIR}/${LEVEL}/*.bats" >/dev/null; then
        DIRS+=("${TESTS_DIR}/${LEVEL}")
    else
        echo "Level ${LEVEL}: no test yet (${TESTS_DIR}/${LEVEL}/*.bats)." >&2
    fi
done
[[ "${#DIRS[@]}" -gt 0 ]] || { echo "ERROR: no test to run." >&2; exit 1; }

export PF_UPDATE_EXPECTED="${UPDATE_EXPECTED}"
exec bats ${BATS_ARGS[@]+"${BATS_ARGS[@]}"} "${DIRS[@]}"
