#!/usr/bin/env bash
#
# common.bash - helpers loaded by every test file (load ../helpers/common)
#
# Every test runs in its own temporary folder (BATS_TEST_TMPDIR), with HOME pointing inside it, so a test never
# reads or writes the real ~/prokfinder-refdb or a results folder of the user.

# $status and $output are set by "run" of bats
# shellcheck disable=SC2154

PF_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
PF_MAIN="${PF_ROOT}/main-prokfinder.sh"
PF_TESTS="${PF_ROOT}/tests"
# Reference database fixture (tests/data/make-fixture.sh): formatted tables and the raw files they are built from
PF_FIXTURE_REFDB="${PF_TESTS}/data/refdb"
PF_FIXTURE_RAW="${PF_TESTS}/data/refdb-raw"
export PF_ROOT PF_MAIN PF_TESTS PF_FIXTURE_REFDB PF_FIXTURE_RAW

# Called by the setup() of each test file. Python packages installed with "pip install --user" (e.g., pyrodigal) stay
# visible after HOME changes.
pf_test_setup() {
    export PYTHONUSERBASE="${PYTHONUSERBASE:-${HOME}/.local}"
    export HOME="${BATS_TEST_TMPDIR}/home"
    export TMPDIR="${BATS_TEST_TMPDIR}/tmp"
    export NO_COLOR=1 PF_COLOR=0
    unset PROKFINDER_LOG PROKFINDER_COMMON_LOADED PBS_JOBID NCPUS
    mkdir -p "${HOME}" "${TMPDIR}"
    cd "${BATS_TEST_TMPDIR}" || return 1
}

# Runs a snippet of bash with lib/common.sh loaded, in a child bash (common.sh sets an EXIT trap, which must not
# replace the one of bats)
# Usage: run pf_eval '<code>' [< input]
pf_eval() {
    bash -c 'set -euo pipefail; source "${PF_ROOT}/lib/common.sh"; eval "$1"' pf_eval "$1"
}

# Prints the value of a variable of lib/common.sh (e.g., PF_REFDB_FORMAT_NCBI)
pf_var() {
    pf_eval "printf '%s\n' \"\${$1}\""
}

# Writes the checkpoints of the three reference databases in <refdb_dir> with the formats expected by the code
# (or <format> for every database), without any table: enough for the checks made before a run
# Usage: make_refdb_markers <refdb_dir> [format]
make_refdb_markers() {
    local DB FORMAT
    for DB in NCBI BACDIVE GTDB; do
        FORMAT="${2:-$(pf_var "PF_REFDB_FORMAT_${DB}")}"
        mkdir -p "$1/${DB}"
        printf 'format=%s\n' "${FORMAT}" > "$1/${DB}/COMPLETED-DOWNLOAD.txt"
    done
}

# Runs Prokfinder on a terminal (util-linux script), typing <answer> to its question; skips when script is missing
# Usage: run_on_terminal <answer> <main-prokfinder.sh arguments...>
run_on_terminal() {
    local ANSWER="$1" CMD
    shift
    command -v script >/dev/null 2>&1 || skip "script (util-linux) not installed"
    CMD="$(printf '%q ' bash "${PF_MAIN}" "$@")"
    run bash -c "printf '%s\n' $(printf '%q' "${ANSWER}") | script -qec $(printf '%q' "${CMD}") /dev/null"
    output="${output//$'\r'/}"
}

# Runs search-genomes on the fixture, writing to the results folder <results>
# Usage: run search_fixture <results> <search-genomes options...>
search_fixture() {
    local RESULTS="$1"
    shift
    bash "${PF_MAIN}" --refdb-dir "${PF_FIXTURE_REFDB}" -o "${RESULTS}" search-genomes "$@"
}

# Prints the accessions selected in <results> (first column of genome-metadata.tsv), sorted
selected_accessions() {
    awk -F'\t' 'NR > 1 { print $1 }' "$1/OUTPUT/GENOME-METADATA/genome-metadata.tsv" | LC_ALL=C sort
}

# Prints the value of <column> of <accession> in a TSV
# Usage: tsv_value <tsv> <accession> <column>
tsv_value() {
    awk -F'\t' -v a="$2" -v c="$3" 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == c) k = i; next } $1 == a && k { print $k }' "$1"
}

############ ASSERTIONS ############
#   They use $status and $output set by "run" and print what was found when they fail.

assert_success() {
    if [[ "${status}" -ne 0 ]]; then
        printf 'expected exit status 0, got %s\noutput:\n%s\n' "${status}" "${output}" >&2
        return 1
    fi
}

# Usage: assert_failure [expected_status]
assert_failure() {
    if [[ "${status}" -eq 0 ]] || [[ -n "${1:-}" && "${status}" -ne "$1" ]]; then
        printf 'expected exit status %s, got %s\noutput:\n%s\n' "${1:-other than 0}" "${status}" "${output}" >&2
        return 1
    fi
}

# Usage: assert_output_contains <text> (fixed string)
assert_output_contains() {
    if [[ "${output}" != *"$1"* ]]; then
        printf 'expected the output to contain:\n  %s\noutput:\n%s\n' "$1" "${output}" >&2
        return 1
    fi
}

refute_output_contains() {
    if [[ "${output}" == *"$1"* ]]; then
        printf 'expected the output NOT to contain:\n  %s\noutput:\n%s\n' "$1" "${output}" >&2
        return 1
    fi
}

assert_output_equals() {
    if [[ "${output}" != "$1" ]]; then
        printf 'expected output:\n%s\ngot:\n%s\n' "$1" "${output}" >&2
        return 1
    fi
}

assert_file_exists() {
    if [[ ! -e "$1" ]]; then
        printf 'file not found: %s\n' "$1" >&2
        return 1
    fi
}

assert_file_not_exists() {
    if [[ -e "$1" ]]; then
        printf 'file should not exist: %s\n' "$1" >&2
        return 1
    fi
}

# Compares two files and shows the differences
# Usage: assert_same_file <expected> <found>
assert_same_file() {
    if ! diff -u "$1" "$2" >&2; then
        printf 'files differ: %s (expected) and %s (found)\n' "$1" "$2" >&2
        return 1
    fi
}

############ EXPECTED RESULTS ############
#   tests/expected/<name> holds the expected version of a table written by Prokfinder. Before the comparison both
#   tables are normalized: the header is kept, the data rows are sorted and the columns given are removed (values that
#   change from one run to another: dates, absolute paths, versions, times).
#   With tests/run-tests.sh --update-expected (PF_UPDATE_EXPECTED=1), the expected file is rewritten instead.

# Usage: normalize_tsv <tsv> [column_to_drop ...]
normalize_tsv() {
    local FILE="$1"
    shift
    awk -F'\t' -v OFS='\t' -v drop="$*" '
        BEGIN { n = split(drop, d, " "); for (i = 1; i <= n; i++) skip[d[i]] = 1 }
        NR == 1 { for (i = 1; i <= NF; i++) keep[i] = !($i in skip) }
        {
            out = ""; first = 1
            for (i = 1; i <= NF; i++) if (keep[i]) { out = first ? $i : out OFS $i; first = 0 }
            print out
        }' "${FILE}" | { IFS= read -r HEADER; printf '%s\n' "${HEADER}"; LC_ALL=C sort; }
}

# Usage: assert_expected_tsv <name in tests/expected> <found tsv> [column_to_drop ...]
assert_expected_tsv() {
    local EXPECTED="${PF_TESTS}/expected/$1"
    local FOUND="$2"
    local NORMALIZED
    NORMALIZED="${BATS_TEST_TMPDIR}/normalized-$(basename "$1")"
    shift 2
    normalize_tsv "${FOUND}" "$@" > "${NORMALIZED}"
    if [[ "${PF_UPDATE_EXPECTED:-0}" -eq 1 ]]; then
        mkdir -p "$(dirname "${EXPECTED}")"
        cp "${NORMALIZED}" "${EXPECTED}"
        return 0
    fi
    assert_file_exists "${EXPECTED}" || { echo "(create it with: tests/run-tests.sh --update-expected)" >&2; return 1; }
    assert_same_file "${EXPECTED}" "${NORMALIZED}"
}
