# fake-lib.bash - sourced by the fake programs of tests/bin (datasets, checkm2, busco, gtdbtk, skder, cidder)
#
# The fake programs write the files that the Prokfinder modules read, in the format of the real programs (copied from
# real runs on the UFV cluster), with results taken from the tables of tests/data/fake-programs. They never use the
# network nor a database. Environment variables (set by the tests):
#   PF_FAKE_LOG        file where every call is appended ("<program> <arguments>"), to count the calls
#   PF_FAKE_DATA       folder of the result tables (default: tests/data/fake-programs)
#   PF_FAKE_GENOMES    folder of the genomes copied by the fake "datasets rehydrate" (default: tests/data/genomes)
#   PF_FAKE_FAIL       space-separated list of programs that must fail (exit 1), e.g. "checkm2"

FAKE_BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Used by the programs that source this file
# shellcheck disable=SC2034
FAKE_DATA="${PF_FAKE_DATA:-${FAKE_BIN_DIR}/../data/fake-programs}"
# shellcheck disable=SC2034
FAKE_GENOMES="${PF_FAKE_GENOMES:-${FAKE_BIN_DIR}/../data/genomes}"

# Records the call and fails when the program is listed in PF_FAKE_FAIL (calls of --version never fail)
# Usage: fake_start <program> "$@"
fake_start() {
    local PROGRAM="$1"
    shift
    if [[ -n "${PF_FAKE_LOG:-}" ]]; then
        printf '%s %s\n' "${PROGRAM}" "$*" >> "${PF_FAKE_LOG}"
    fi
    if [[ " ${PF_FAKE_FAIL:-} " == *" ${PROGRAM} "* && "$*" != *version* ]]; then
        echo "fake ${PROGRAM}: failing on purpose (PF_FAKE_FAIL)" >&2
        exit 1
    fi
}

# Prints the value of an option in the arguments (empty when it is absent)
# Usage: fake_option <--name> "$@"
fake_option() {
    local NAME="$1"
    shift
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == "${NAME}" ]]; then
            printf '%s\n' "${2:-}"
            return 0
        fi
        shift
    done
}

# Prints the values that follow an option, up to the next option (e.g., --genomes a b c --threads 2 -> a b c)
# Usage: fake_option_list <--name> "$@"
fake_option_list() {
    local NAME="$1" ON=0
    shift
    for ARG in "$@"; do
        if [[ "${ARG}" == "${NAME}" ]]; then
            ON=1
        elif [[ "${ARG}" == --* ]]; then
            ON=0
        elif [[ "${ON}" -eq 1 ]]; then
            printf '%s\n' "${ARG}"
        fi
    done
}

# Prints the accession (GCA_/GCF_) found in a file name
fake_accession() {
    basename "$1" | grep -oE '^GC[AF]_[0-9]+[.][0-9]+' || true
}
