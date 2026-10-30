#!/usr/bin/env bash
#
# common.sh - functions and paths shared by main-prokfinder.sh and every module.
# This file is sourced, never executed:
#     source "${SCRIPT_DIR}/../lib/common.sh"

# Load only once, even if several files source it
if [[ -n "${PROKFINDER_COMMON_LOADED:-}" ]]; then
    return 0
fi
PROKFINDER_COMMON_LOADED=1

# Associative arrays (declare -A) and "mapfile" need bash 4 or newer
if (( BASH_VERSINFO[0] < 4 )); then
    echo "ERROR: bash 4 or newer is required (found ${BASH_VERSION})." >&2
    exit 1
fi

############ LOGGING ################

# Colors are used only when the messages are shown on a terminal (and NO_COLOR is not set). The decision is made
# once, by the first script (before its output is copied to the log), and inherited by the modules it calls.
if [[ -z "${PF_COLOR:-}" ]]; then
    if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
        PF_COLOR=1
    else
        PF_COLOR=0
    fi
    export PF_COLOR
fi
if [[ "${PF_COLOR}" -eq 1 ]]; then
    PF_RED=$'\033[1;31m'
    PF_YELLOW=$'\033[1;33m'
    PF_RESET=$'\033[0m'
else
    PF_RED=""
    PF_YELLOW=""
    PF_RESET=""
fi

log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")

    case "${level}" in
        "message")
            echo -e "[${timestamp}] [INFO] ${message}"
            ;;
        "warning")
            echo -e "${PF_YELLOW}[${timestamp}] [WARNING] ${message}${PF_RESET}" >&2
            ;;
        "error")
            echo -e "${PF_RED}[${timestamp}] [ERROR] ${message}${PF_RESET}" >&2
            ;;
        *)
            echo -e "[${timestamp}] [LOG] ${message}"
            ;;
    esac
}

# Logs an error and stops the script
die() {
    log "error" "$1"
    exit "${2:-1}"
}

# Temporary directories registered here are removed when the script ends (see _pf_on_exit)
PF_TEMP_DIRS=()
PF_TEE_ACTIVE=0

# Creates a temporary directory and stores its path in the variable named <var_name>.
# (It cannot be used as $(make_temp_dir): the registration would be lost in the subshell.)
# Usage: make_temp_dir <var_name>
make_temp_dir() {
    local DIR
    DIR="$(mktemp -d "${TMPDIR:-/tmp}/prokfinder.XXXXXX")"
    PF_TEMP_DIRS+=("${DIR}")
    printf -v "$1" '%s' "${DIR}"
}

# Marker of a run in progress in a results folder (see pf_mark_results_dir_in_use); removed when the run ends
PF_RUN_FILE=""

# Single EXIT handler: removes the temporary directories and the marker of the run, and lets tee finish writing
# the log
_pf_on_exit() {
    local RC=$?
    local DIR
    for DIR in ${PF_TEMP_DIRS[@]+"${PF_TEMP_DIRS[@]}"}; do
        rm -rf -- "${DIR}"
    done
    if [[ -n "${PF_RUN_FILE}" ]] && grep -qx "pid=$$" "${PF_RUN_FILE}" 2>/dev/null; then
        rm -f -- "${PF_RUN_FILE}"
    fi
    if [[ "${PF_TEE_ACTIVE}" -eq 1 ]]; then
        exec 1>&- 2>&-
        wait
    fi
    exit "${RC}"
}
trap _pf_on_exit EXIT
# A run stopped by a signal (e.g., qdel sends SIGTERM) also goes through the EXIT handler
trap 'exit 143' TERM
trap 'exit 130' INT

############ RUNS IN A RESULTS FOLDER ################
#   Only one Prokfinder run may write to a results folder at a time. Two records are kept in it:
#     PBS-JOBS/submitted-jobs.tsv   one line per job submitted by run-on-cluster: <job id> <date> <.pbs> <arguments>
#     .prokfinder-running           the run in progress (host, PID and PBS job id), removed when it ends

pf_pbs_jobs_file_name() { echo "submitted-jobs.tsv"; }
pf_run_file()           { echo "$1/.prokfinder-running"; }

# Prints the PBS state of a job (Q queued, R running, H held, E exiting...), or nothing when the job has finished,
# is unknown or PBS is not available
# Usage: pf_job_state <job_id>
pf_job_state() {
    command -v qstat >/dev/null 2>&1 || return 0
    qstat -f "$1" 2>/dev/null | awk '$1 == "job_state" { print $3; exit }' || true
}

# Writes the marker of the run in progress in <results_dir> (removed by the EXIT handler)
# Usage: pf_mark_results_dir_in_use <results_dir> <command>
pf_mark_results_dir_in_use() {
    PF_RUN_FILE="$(pf_run_file "$1")"
    {
        echo "host=$(hostname)"
        echo "pid=$$"
        echo "job=${PBS_JOBID:-}"
        echo "started=$(date +"%Y-%m-%d %H:%M:%S")"
        echo "command=$2"
    } > "${PF_RUN_FILE}"
}

# Copies everything printed by the script (stdout and stderr) to <log_file>, appending to it.
# The terminal keeps the colors; the color codes are removed from the copy written to the log file.
# Usage: start_logging <log_file>
start_logging() {
    mkdir -p "$(dirname "$1")"
    exec 3>&1
    exec > >(tee /dev/fd/3 | sed -u $'s/\033\\[[0-9;]*m//g' >> "$1") 2>&1
    exec 3>&-
    PF_TEE_ACTIVE=1
}

# A module run on its own writes its own log. When it is called by main-prokfinder.sh (PROKFINDER_LOG is set),
# its output already goes to the main log, so nothing is done.
# Usage: setup_module_log <log_file>
setup_module_log() {
    if [[ -z "${PROKFINDER_LOG:-}" ]]; then
        start_logging "$1"
    fi
}

############ FILE AND TABLE HELPERS ################

# Prints the number of data rows of a TSV file (header excluded)
count_records() {
    local LINES
    LINES=$(wc -l < "$1")
    echo $(( LINES > 0 ? LINES - 1 : 0 ))
}

# Prints the number of lines of a file (0 if it does not exist)
count_lines() {
    if [[ -f "$1" ]]; then
        wc -l < "$1"
    else
        echo 0
    fi
}

# Prints the modification time of a file in seconds (0 if it does not exist)
file_mtime() {
    stat -c %Y -- "$1" 2>/dev/null || echo 0
}

# Prints the 1-based position of the first column whose header matches one of the given names.
# The comparison ignores case and every character that is not a letter or a digit, so
# "ASSEMBLY_ACCESSION", "Assembly Accession" and "assemblyaccession" are the same name.
# Prints nothing if there is no match.
# Usage: get_column_index <tsv_file> <name> [alternative_name ...]
get_column_index() {
    local FILE="$1"
    shift
    head -n 1 "${FILE}" | awk -F'\t' -v names="$*" '
    function key(s) { s = tolower(s); gsub(/[^a-z0-9]/, "", s); return s }
    BEGIN { n = split(names, w, " "); for (k = 1; k <= n; k++) wanted[k] = key(w[k]) }
    {
        for (k = 1; k <= n; k++)
            for (i = 1; i <= NF; i++)
                if (key($i) == wanted[k]) { print i; exit }
    }'
}

# Same as get_column_index, but stops the script with a clear message if the column does not exist
# Usage: COLUMN=$(require_column <tsv_file> <name> [alternative_name ...])
require_column() {
    local FILE="$1"
    local INDEX
    shift
    INDEX="$(get_column_index "${FILE}" "$@")"
    if [[ -z "${INDEX}" ]]; then
        log "error" "Column '$1' not found in ${FILE}. Is the file tab-separated?"
        exit 1
    fi
    echo "${INDEX}"
}

############ EMPTY AND INVALID VALUES (NULL) ################
#   One rule for every reference table: a cell whose value is empty or means "no information" becomes NULL. Each
#   database records the values it converted in NULL-VALUES-<DB>.tsv (pf_write_null_mapping), so the conversion can
#   be checked. Rules (case-insensitive, after trimming the spaces):
#     EMPTY            the cell is empty
#     DASH             only dashes ("-", "--")
#     INVALID_WORD     null, na, n/a, nd, nan, none, unknown, missing
#     NO_INFO_PREFIX   starts with "not " / "missing " ("not applicable", "not collected", "missing: data agreement...")

# awk functions of the rule: pf_null_rule(v) prints the rule that makes v NULL ("" when v is valid);
# pf_null_record(column, v, rule) counts a conversion; pf_null_write(file, table) appends the counts to <file> as
# <table> TAB <column> TAB <original value> TAB <rule> TAB <occurrences>
PF_AWK_NULL='
function pf_null_rule(v,   l) {
    l = tolower(v)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", l)
    if (l == "") return "EMPTY"
    if (l ~ /^-+$/) return "DASH"
    if (l ~ /^(null|na|n\/a|nd|nan|none|unknown|missing)$/) return "INVALID_WORD"
    if (l ~ /^(not|missing)[ _:-]/) return "NO_INFO_PREFIX"
    return ""
}
function pf_null_record(column, v, rule) { pf_null_count[column SUBSEP v SUBSEP rule]++ }
function pf_null_write(file, table,   k, p) {
    if (file == "") return
    for (k in pf_null_count) {
        split(k, p, SUBSEP)
        printf "%s\t%s\t%s\t%s\t%d\n", table, p[1], p[2], p[3], pf_null_count[k] >> file
    }
    close(file)
}
'

# Writes the mapping of the values converted to NULL (rows appended by pf_null_write) with its header, the same
# value of the same column summed over the parts, sorted by table, column and occurrences
# Usage: pf_write_null_mapping <output.tsv> <rows file> [rows file ...]
pf_write_null_mapping() {
    local OUT="$1"
    shift
    {
        printf 'SOURCE_TABLE\tCOLUMN\tORIGINAL_VALUE\tRULE\tCONVERTED_TO\tOCCURRENCES\n'
        cat "$@" 2>/dev/null | awk -F'\t' -v OFS='\t' '
            { n[$1 SUBSEP $2 SUBSEP $3 SUBSEP $4] += $5 }
            END { for (k in n) { split(k, p, SUBSEP); print p[1], p[2], (p[3] == "" ? "(empty)" : p[3]), p[4], "NULL", n[k] } }' \
            | LC_ALL=C sort -t $'\t' -k1,1 -k2,2 -k6,6nr
    } > "${OUT}.tmp"
    mv "${OUT}.tmp" "${OUT}"
}

# Formats a TSV read from stdin and writes it to stdout:
#   - header: spaces are replaced by "_" (with <upper> = 1 the header is also converted to upper case and every
#     run of characters other than letters/digits becomes "_", e.g. "Assembly BioSample Isolation source" ->
#     ASSEMBLY_BIOSAMPLE_ISOLATION_SOURCE)
#   - cells: trimmed; empty or invalid values (see PF_AWK_NULL) -> NULL; with <null_rows> the converted values are
#     appended to it (pf_null_write), under the name <table>
#   - every row gets the same number of columns as the header (missing cells -> NULL)
# Usage: format_tsv <upper: 0|1> [<null_rows> <table>] < input.tsv > output.tsv
format_tsv() {
    awk -F'\t' -v OFS='\t' -v upper="${1:-0}" -v null_rows="${2:-}" -v table="${3:-}" "${PF_AWK_NULL}"'
    NR == 1 {
        for (i = 1; i <= NF; i++) {
            h = $i
            gsub(/\r/, "", h)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", h)
            if (upper + 0) { h = toupper(h); gsub(/[^A-Z0-9]+/, "_", h); gsub(/^_+|_+$/, "", h) }
            else gsub(/[[:space:]]+/, "_", h)
            $i = h
            name[i] = h
        }
        nh = NF
        print
        next
    }
    {
        for (i = 1; i <= nh; i++) {
            v = (i <= NF ? $i : "")
            gsub(/\r/, "", v)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
            if (v != "NULL" && (rule = pf_null_rule(v)) != "") {
                if (null_rows != "") pf_null_record(name[i], v, rule)
                v = "NULL"
            }
            $i = v
        }
        NF = nh
        print
    }
    END { pf_null_write(null_rows, table) }'
}

# Adds the columns of <table> to <master>. In both files the first column is the assembly accession.
# Columns of <master> with the same name as a column of <table> are replaced, so a stage can be re-run
# and its columns are simply refreshed. Accessions missing from <table> get NULL in the new columns.
# Usage: add_metadata_columns <master_tsv> <table_tsv>
add_metadata_columns() {
    local MASTER="$1"
    local TABLE="$2"

    if [[ ! -s "${TABLE}" ]]; then
        log "warning" "Table ${TABLE} is empty or missing: no column was added to ${MASTER}."
        return 0
    fi

    awk -F'\t' -v OFS='\t' -v table="${TABLE}" '
    BEGIN {
        getline line < table
        nt = split(line, th, "\t")
        for (i = 2; i <= nt; i++) newcol[th[i]] = 1
        while ((getline line < table) > 0) {
            split(line, f, "\t")
            row[f[1]] = line
        }
        close(table)
    }
    NR == 1 {
        nk = 0
        for (i = 1; i <= NF; i++) if (!($i in newcol)) keep[++nk] = i
        out = $(keep[1])
        for (k = 2; k <= nk; k++) out = out OFS $(keep[k])
        for (i = 2; i <= nt; i++) out = out OFS th[i]
        print out
        next
    }
    {
        out = $(keep[1])
        for (k = 2; k <= nk; k++) out = out OFS $(keep[k])
        if ($1 in row) {
            n = split(row[$1], f, "\t")
            for (i = 2; i <= nt; i++) out = out OFS ((i <= n && f[i] != "") ? f[i] : "NULL")
        } else {
            for (i = 2; i <= nt; i++) out = out OFS "NULL"
        }
        print out
    }' "${MASTER}" > "${MASTER}.tmp"
    mv "${MASTER}.tmp" "${MASTER}"
}

# Prints the accessions (first column) of the rows of <tsv> whose column <column_name> has one of the given values
# Usage: select_accessions <tsv> <column_name> <value> [value ...]
select_accessions() {
    local FILE="$1"
    local COLUMN_NAME="$2"
    local COLUMN
    shift 2
    COLUMN="$(require_column "${FILE}" "${COLUMN_NAME}")"
    awk -F'\t' -v c="${COLUMN}" -v values="$*" '
        BEGIN { n = split(values, v, " "); for (i = 1; i <= n; i++) want[v[i]] = 1 }
        NR > 1 && ($c in want) { print $1 }
    ' "${FILE}"
}

# Prints the path of the genome file of <accession> in <dir> (<accession>.fna or <accession>.fna.gz),
# or nothing if there is none
# Usage: genome_file_of <dir> <accession>
genome_file_of() {
    if [[ -f "$1/$2.fna" ]]; then
        echo "$1/$2.fna"
    elif [[ -f "$1/$2.fna.gz" ]]; then
        echo "$1/$2.fna.gz"
    fi
}

# Prints a path as an absolute path (the file or folder must exist)
absolute_path() {
    if [[ -d "$1" ]]; then
        (cd "$1" && pwd)
    else
        echo "$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
    fi
}

############ PER-GENOME RESULT CACHES ################
#   A cache table keeps the result of each genome with the modification time of its input file
#   (<accession> <TAB> <mtime> <TAB> <results...>, with a header), so only new or changed genomes are run again.

# Prints the rows of <genomes.tsv> (<accession> <TAB> <file> <TAB> <mtime> ...) whose (accession, mtime) is not in
# <cache>
# Usage: pending_for_cache <cache> <genomes.tsv>
pending_for_cache() {
    awk -F'\t' 'NR == FNR { if (FNR > 1) done[$1 SUBSEP $2] = 1; next } !(($1 SUBSEP $3) in done)' "$1" "$2"
}

# Adds <new_rows> to <cache>, replacing the old rows of the same accessions
# Usage: update_cache <cache> <new_rows>
update_cache() {
    local CACHE="$1"
    local NEW_ROWS="$2"
    { head -n 1 "${CACHE}"; { cat "${NEW_ROWS}"; tail -n +2 "${CACHE}"; } | awk -F'\t' '!seen[$1]++' | LC_ALL=C sort -t $'\t' -k1,1; } > "${CACHE}.tmp"
    mv "${CACHE}.tmp" "${CACHE}"
}

# Prints a Python interpreter that has the "pyrodigal" package (nothing if there is none): python3/python of the
# PATH, or the Python of the environment of skDER/CiDDER, which use Pyrodigal (on the UFV cluster, module skder)
pf_python_with_pyrodigal() {
    local CANDIDATE TOOL
    local -a CANDIDATES=(python3 python)
    for TOOL in cidder skder; do
        if command -v "${TOOL}" >/dev/null 2>&1; then
            CANDIDATES+=("$(dirname "$(command -v "${TOOL}")")/python3" "$(dirname "$(command -v "${TOOL}")")/python")
        fi
    done
    for CANDIDATE in "${CANDIDATES[@]}"; do
        if command -v "${CANDIDATE}" >/dev/null 2>&1 && "${CANDIDATE}" -c "import pyrodigal" >/dev/null 2>&1; then
            command -v "${CANDIDATE}"
            return 0
        fi
    done
}

# Runs a program with the folder of its own executable first in the PATH. A program installed in its own conda
# environment that starts with "#!/usr/bin/env python3" (e.g., BUSCO) would otherwise run with the python3 of another
# environment that comes first in the PATH (on the UFV cluster, the module skder, loaded last) and fail with "No
# module named ...". The helpers of the program (e.g., hmmsearch for BUSCO) are also taken from its environment.
# Usage: run_in_own_env <program> [arguments]
run_in_own_env() {
    local BIN_DIR
    BIN_DIR="$(dirname "$(command -v "$1")")"
    PATH="${BIN_DIR}:${PATH}" "$@"
}

# Returns 0 if the version <version> is the same as or newer than <minimum> (numbers separated by dots)
# Usage: pf_version_ge <version> <minimum>
pf_version_ge() {
    [[ "$(printf '%s\n%s\n' "$1" "$2" | LC_ALL=C sort -V | awk 'NR == 1')" == "$2" ]]
}

# The oldest CiDDER that dereplicates predicted proteomes (1.3.6 stops without genome files; fixed in 1.3.7)
# shellcheck disable=SC2034  # used by the modules
PF_CIDDER_MIN_PROTEOME_VERSION=1.3.7

############ CITATIONS ################

# Prints the DOIs (or the website) to cite for a component of versions.tsv, separated by "; " (CITATIONS.md has the
# full references; a new program or database gets a line here and in CITATIONS.md). Nothing for an unknown component.
# Usage: pf_citation <component>
pf_citation() {
    case "$1" in
        prokfinder)                 echo "https://github.com/LBCM-UFV/prokfinder-pipeline" ;;
        datasets|NCBI)              echo "10.1038/s41597-024-03571-y" ;;
        ncbi-taxdump)               echo "10.1093/database/baaa062" ;;
        seqkit)                     echo "10.1002/imt2.191" ;;
        pyrodigal)                  echo "10.21105/joss.04296; 10.1186/1471-2105-11-119" ;;
        checkm2|checkm2-database)   echo "10.1038/s41592-023-01940-w" ;;
        busco|busco-lineages)       echo "10.1093/nar/gkae987; 10.1093/molbev/msab199" ;;
        gtdbtk)                     echo "10.1093/bioinformatics/btac672; 10.1038/s41592-023-02018-3" ;;
        skder)                      echo "10.1099/mgen.0.001438; 10.1038/s41592-023-02018-3" ;;
        cidder)                     echo "10.1099/mgen.0.001438" ;;
        BACDIVE)                    echo "10.1093/nar/gkae959; 10.1093/nar/gkab961" ;;
        GTDB|gtdbtk-reference)      echo "10.1093/nar/gkaf1040; 10.1093/nar/gkab776" ;;
        Rscript)                    echo "https://www.r-project.org" ;;
    esac
}

############ RESOURCES ################

# RAM (GB) that CheckM2 needs in its normal mode: it used 17.3 GB with 166 genomes and 8 CPUs on the UFV cluster.
# With less, CheckM2 runs with --lowmem (smaller DIAMOND blocks: less RAM, slower). Used by the modules.
# shellcheck disable=SC2034
PF_CHECKM2_MIN_MEMORY_GB=18

# Prints an amount of RAM in GB, rounded down: "20gb", "20g" or "20" -> 20; "24000mb" -> 23. Returns 1 (prints
# nothing) if the format is invalid.
# Usage: pf_memory_gb <ram>
pf_memory_gb() {
    local VALUE="${1,,}"
    if [[ "${VALUE}" =~ ^([0-9]+)(gb|g)?$ ]]; then
        echo $(( 10#${BASH_REMATCH[1]} ))
    elif [[ "${VALUE}" =~ ^([0-9]+)(mb|m)$ ]]; then
        echo $(( 10#${BASH_REMATCH[1]} / 1024 ))
    else
        return 1
    fi
}

# Prints the total RAM of the computer in GB (rounded down), or nothing when it cannot be found
pf_system_memory_gb() {
    if [[ -r /proc/meminfo ]]; then
        awk '$1 == "MemTotal:" { printf "%d\n", $2 / 1048576; exit }' /proc/meminfo
    elif command -v sysctl >/dev/null 2>&1; then
        sysctl -n hw.memsize 2>/dev/null | awk '{ printf "%d\n", $1 / 1073741824 }'
    fi
}

# Stops the script if one of the given programs is not in the PATH
# Usage: require_programs <program> [program ...]
require_programs() {
    local PROGRAM
    local MISSING=()
    for PROGRAM in "$@"; do
        if ! command -v "${PROGRAM}" >/dev/null 2>&1; then
            MISSING+=("${PROGRAM}")
        fi
    done
    if [[ "${#MISSING[@]}" -gt 0 ]]; then
        die "Program(s) not found in the PATH: ${MISSING[*]}"
    fi
}

############ PATHS OF THE REFERENCE DATABASE ################
#
# Every module builds the paths of the reference tables with these functions, so the layout of
# ~/prokfinder-refdb is defined in a single place.

# Domains handled by Prokfinder (same order everywhere)
# shellcheck disable=SC2034  # used by the modules
PF_DOMAINS=("BACTERIA" "ARCHAEA")

# NCBI (<ncbi_dir> = .../REFERENCE-METADATA/NCBI; <source> = genbank | refseq)
pf_ncbi_genomes_dir()   { echo "$1/$2-NCBI-GENOMES"; }
pf_ncbi_fetch_file()    { echo "$1/$2-NCBI-GENOMES/fetch.txt"; }
pf_ncbi_metadata_dir()  { echo "$1/$2-NCBI-METADATA"; }
pf_ncbi_metadata_table() { echo "$1/$2-NCBI-METADATA/$3-metadata.tsv"; }
pf_ncbi_complete_table() { echo "$1/$2-NCBI-METADATA/complete-metadata.tsv"; }
pf_ncbi_taxdump_dir()   { echo "$1/TAXDUMP"; }
# TaxID normalization (normalize-ncbi-taxids.sh): derived table next to each NCBI table, report and checkpoint
pf_ncbi_taxid_status_table() { echo "$1/$2-NCBI-METADATA/$3-taxid-status.tsv"; }
pf_ncbi_taxid_report()  { echo "$1/taxid-unresolved.tsv"; }
pf_taxid_marker()       { echo "$1/TAXID-NORMALIZATION-COMPLETED.txt"; }
# Prints the value of the first "<key>=<value>" line of the TaxID normalization checkpoint (nothing if there is none)
# Usage: pf_taxid_marker_value <ncbi_dir> <key>
pf_taxid_marker_value() {
    sed -n "s/^$2=//p" "$(pf_taxid_marker "$1")" 2>/dev/null | awk 'NR == 1' || true
}

# BacDive (<bacdive_dir> = .../REFERENCE-METADATA/BACDIVE)
pf_bacdive_brute_dir()  { echo "$1/BACDIVE-DOWNLOAD-BRUTE"; }
pf_bacdive_table()      { echo "$1/BACDIVE-FORMATTED-TSV/BACDIVE_DATA_FORMATTED.tsv"; }
pf_bacdive_strain_table()  { echo "$1/BACDIVE-FORMATTED-TSV/BACDIVE_CONCATENATED_REFERENCES_FOR_STRAIN.tsv"; }
pf_bacdive_species_table() { echo "$1/BACDIVE-FORMATTED-TSV/BACDIVE_CONCATENATED_STRAINS_FOR_SPECIES.tsv"; }
pf_bacdive_taxid_status_table() { echo "$1/BACDIVE-FORMATTED-TSV/bacdive-taxid-status.tsv"; }

# GTDB (<gtdb_dir> = .../REFERENCE-METADATA/GTDB)
pf_gtdb_prefix() {
    case "$1" in
        BACTERIA) echo "bac120" ;;
        ARCHAEA)  echo "ar53" ;;
        *) die "Unknown domain: $1" ;;
    esac
}
pf_gtdb_taxonomy_table() { echo "$1/$2-GTDB-TAXONOMY/$(pf_gtdb_prefix "$2")_taxonomy_formatted.tsv"; }
pf_gtdb_metadata_table() { echo "$1/$2-GTDB-METADATA/$(pf_gtdb_prefix "$2")_metadata_formatted.tsv"; }
pf_gtdb_version_file()   { echo "$1/VERSION.txt"; }

# Checkpoint written by each download module when it finishes successfully
pf_completed_marker()    { echo "$1/COMPLETED-DOWNLOAD.txt"; }

# Format of the tables written by each download module. It is recorded in the checkpoint ("format=<n>"); when a
# module changes the tables it writes, its number is increased, and Prokfinder runs the module again: the tables
# are rebuilt from the files already downloaded (nothing is downloaded again).
# shellcheck disable=SC2034  # used by the modules
PF_REFDB_FORMAT_NCBI=4      # 3: NULL-VALUES-NCBI.tsv (values converted to NULL)
#                             4: no NCBI lineage columns (NCBI_<RANK>, NCBI_<RANK>_TAXID: the TaxIDs are normalized in
#                                <source>-taxid-status.tsv); paired GenBank/RefSeq accession and NCBI_<GENBANK|REFSEQ>_ASSEMBLY_ACCESSION
# shellcheck disable=SC2034
PF_REFDB_FORMAT_BACDIVE=4   # 3: NULL-VALUES-BACDIVE.tsv
#                             4: no ncbi_tax_id_rank column (the rank is in bacdive-taxid-status.tsv)
# shellcheck disable=SC2034
PF_REFDB_FORMAT_GTDB=4      # 3: status of each genome in GTDB (species representative, type material) in the taxonomy;
#                             4: the same NULL rule for these columns ("not used as type" -> NULL), NULL-VALUES-GTDB.tsv

# Returns 0 if the checkpoint of <db_dir> exists and records the table format <version>
# Usage: pf_refdb_format_ok <db_dir> <version>
pf_refdb_format_ok() {
    grep -qx "format=$2" "$(pf_completed_marker "$1")" 2>/dev/null
}

# Reference databases packaged on Zenodo (registry: refdb-zenodo.tsv; format in its header)
# Prints the value of a HOST or RECORD line
# Usage: pf_registry_value <registry> HOST|RECORD
pf_registry_value() {
    awk -F'\t' -v key="$2" '{ sub(/\r$/, "") } $1 == key { print $2; exit }' "$1"
}

# Prints "<file><TAB><md5>" of the package of a database with the given table format (nothing if there is none)
# Usage: pf_registry_package <registry> <DB> <format>
pf_registry_package() {
    awk -F'\t' -v db="$2" -v fmt="$3" '{ sub(/\r$/, "") } $1 == "PACKAGE" && $2 == db && $3 == fmt { print $4 "\t" $5; exit }' "$1"
}

# Returns 0 if <db_dir> was installed from a Zenodo package (so it has no raw files to rebuild the tables from)
# Usage: pf_refdb_from_package <db_dir>
pf_refdb_from_package() {
    grep -q '^package=' "$(pf_completed_marker "$1")" 2>/dev/null
}

# Prints the value of the first "<key>=<value>" line of the checkpoint of <db_dir> (nothing if there is none)
# Usage: pf_marker_value <db_dir> <key>
pf_marker_value() {
    sed -n "s/^$2=//p" "$(pf_completed_marker "$1")" 2>/dev/null | awk 'NR == 1' || true
}

# Returns 1 if the registry has, for the table format <format>, another package than the one installed in <db_dir>
# (another record, file or MD5: a newer package was published); 0 otherwise, also when the registry has no package of
# that format
# Usage: pf_refdb_package_current <registry> <DB> <format> <db_dir>
pf_refdb_package_current() {
    local ENTRY MARKER RECORD MD5
    ENTRY="$(pf_registry_package "$1" "$2" "$3")"
    RECORD="$(pf_registry_value "$1" RECORD)"
    [[ -n "${ENTRY}" && -n "${RECORD}" ]] || return 0
    MARKER="$(pf_completed_marker "$4")"
    grep -qxF "package=zenodo:${RECORD}:${ENTRY%%$'\t'*}" "${MARKER}" 2>/dev/null || return 1
    # (packages installed before the MD5 was recorded are compared by record and file only)
    MD5="$(sed -n 's/^package_md5=//p' "${MARKER}" | awk 'NR == 1')"
    [[ -z "${MD5}" || "${MD5}" == "${ENTRY#*$'\t'}" ]]
}

# Downloads the Zenodo package of a database, checks its MD5 and extracts it into <target_dir> (which must be empty or
# new). The package must record the table format the code expects. Stops with an error otherwise. A download
# interrupted (a partial file in <download_dir>) is resumed by the next call.
# Usage: pf_install_refdb_package <registry> <DB> <format> <target_dir> <download_dir>
pf_install_refdb_package() {
    local REGISTRY="$1" DB="$2" FORMAT="$3" TARGET="$4" WORK="$5"
    local HOST RECORD ENTRY FILE MD5 URL
    [[ -f "${REGISTRY}" ]] || die "Registry of the Zenodo packages not found: ${REGISTRY}."
    HOST="$(pf_registry_value "${REGISTRY}" HOST)"
    RECORD="$(pf_registry_value "${REGISTRY}" RECORD)"
    ENTRY="$(pf_registry_package "${REGISTRY}" "${DB}" "${FORMAT}")"
    if [[ -z "${HOST}" || -z "${RECORD}" || -z "${ENTRY}" ]]; then
        die "No Zenodo package with the ${DB} table format ${FORMAT} that this version of Prokfinder reads (registry ${REGISTRY}). Use setup --from-source to build the database from its sources."
    fi
    FILE="${ENTRY%%$'\t'*}"
    MD5="${ENTRY#*$'\t'}"
    URL="https://${HOST}/records/${RECORD}/files/${FILE}?download=1"

    mkdir -p "${WORK}" "${TARGET}"
    if [[ -f "${WORK}/${FILE}" && "$(md5sum "${WORK}/${FILE}" | cut -d' ' -f1)" == "${MD5}" ]]; then
        log "message" "${DB}: package ${FILE} already downloaded."
    else
        local RC=0
        if [[ -s "${WORK}/${FILE}" ]]; then
            log "message" "${DB}: resuming the download of ${FILE} from Zenodo (record ${RECORD} on ${HOST})..."
            curl -fL --retry 3 --retry-delay 10 -C - -o "${WORK}/${FILE}" "${URL}" || RC=$?
            # A partial file that cannot be completed (server without byte ranges, or a file of another package with
            # the same name) is downloaded again from the start
            if [[ "${RC}" -eq 33 || "${RC}" -eq 36 ]] \
                || [[ "${RC}" -eq 0 && "$(md5sum "${WORK}/${FILE}" | cut -d' ' -f1)" != "${MD5}" ]]; then
                log "warning" "${DB}: the partial file ${FILE} could not be completed; downloading it again from the start."
                rm -f "${WORK}/${FILE}"
                RC=0
            fi
        fi
        if [[ ! -s "${WORK}/${FILE}" ]]; then
            log "message" "${DB}: downloading ${FILE} from Zenodo (record ${RECORD} on ${HOST})..."
            curl -fL --retry 3 --retry-delay 10 -o "${WORK}/${FILE}" "${URL}" || RC=$?
        fi
        [[ "${RC}" -eq 0 ]] || die "Download of ${URL} failed. Check the connection and run setup again (the download is resumed)."
        [[ "$(md5sum "${WORK}/${FILE}" | cut -d' ' -f1)" == "${MD5}" ]] \
            || { rm -f "${WORK}/${FILE}"; die "MD5 of ${FILE} differs from the registry (${MD5}); the file was removed. Run setup again."; }
    fi
    tar -xzf "${WORK}/${FILE}" -C "${TARGET}" --strip-components=1 || die "Could not extract ${WORK}/${FILE}."
    pf_refdb_format_ok "${TARGET}" "${FORMAT}" || die "The package ${FILE} does not record the table format ${FORMAT}."
    printf 'package=zenodo:%s:%s\npackage_md5=%s\n' "${RECORD}" "${FILE}" "${MD5}" >> "$(pf_completed_marker "${TARGET}")"
    rm -f "${WORK}/${FILE}"
}

############ HELP IN BOXES ############

# Width of the help boxes: the terminal width (60-100) when the output is a terminal, otherwise 80
pf_help_width() {
    local WIDTH=80
    if [[ -t 1 ]]; then
        WIDTH="${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}"
        [[ "${WIDTH}" =~ ^[0-9]+$ ]] || WIDTH=80
        (( WIDTH >= 60 )) || WIDTH=60
        (( WIDTH <= 100 )) || WIDTH=100
    fi
    echo "${WIDTH}"
}

# Prints the rows read from stdin inside a box with a title (the help of the options, as in rich/typer programs).
# A row "  <names>  <description>" (two spaces, then a name that is not "- ", and two or more spaces before the
# description) is shown in two columns, with the description wrapped; a line indented by 4 or more spaces continues
# the row above; any other line is plain text, wrapped. Only ASCII text is allowed in the rows (the widths are counted
# in characters).
# Usage: pf_help_box <title> < rows
pf_help_box() {
    awk -v title="$1" -v width="$(pf_help_width)" '
    function wrap(text, w, indent,   out, line, n, i, words, pad) {
        # words of text, lines of at most w characters, the next lines indented by "indent" spaces
        n = split(text, words, " ")
        out = ""; line = ""; pad = sprintf("%" indent "s", "")
        for (i = 1; i <= n; i++) {
            if (line == "") line = words[i]
            else if (length(line) + 1 + length(words[i]) <= w - (out == "" ? 0 : indent)) line = line " " words[i]
            else { out = out (out == "" ? "" : "\n" pad) line; line = words[i] }
        }
        return out (out == "" ? "" : (line == "" ? "" : "\n" pad)) line
    }
    function emit(s, w) { printf "\342\224\202 %s%*s \342\224\202\n", s, w - length(s), "" }
    BEGIN { inner = width - 4 }
    {
        sub(/\r$/, "")
        if ($0 ~ /^ {4,}[^ ]/ && n > 0) { v = $0; sub(/^ +/, "", v); desc[n] = desc[n] (desc[n] == "" ? "" : " ") v; next }
        n++
        line = substr($0, 3)
        if (($0 ~ /^  [^ -]/ || $0 ~ /^  -[^ ]/) && (match(line, /  +/) || $0 ~ /^  -/)) {
            if (match(line, /  +/)) { name[n] = substr(line, 1, RSTART - 1); desc[n] = substr(line, RSTART + RLENGTH) }
            else { name[n] = line; desc[n] = "" }
            kind[n] = "row"
            if (length(name[n]) > wname && length(name[n]) <= 40) wname = length(name[n])
        } else {
            kind[n] = "text"; desc[n] = ($0 ~ /^  / ? line : $0); sub(/[ ]+$/, "", desc[n])
        }
    }
    END {
        # top border: "+- Title ----+"
        printf "\342\225\255\342\224\200 %s ", title
        for (i = 0; i < width - length(title) - 5; i++) printf "\342\224\200"
        printf "\342\225\256\n"
        for (r = 1; r <= n; r++) {
            if (kind[r] == "row") {
                dw = inner - wname - 2
                text = wrap(desc[r], dw, 0)
                m = split(text, dl, "\n")
                if (m == 0) { m = 1; dl[1] = "" }
                nm = name[r]
                if (length(nm) > wname) { emit(nm, inner); nm = "" }
                for (k = 1; k <= m; k++) {
                    emit(sprintf("%-" wname "s  %s", (k == 1 ? nm : ""), dl[k]), inner)
                }
            } else {
                if (desc[r] == "") { emit("", inner); continue }
                lead = match(desc[r], /[^ ]/) - 1
                hang = lead + (substr(desc[r], lead + 1, 2) == "- " ? 2 : 0)
                text = wrap(substr(desc[r], lead + 1), inner - lead, hang - lead)
                m = split(text, dl, "\n")
                for (k = 1; k <= m; k++) emit(sprintf("%" lead "s%s", "", dl[k]), inner)
            }
        }
        printf "\342\225\260"
        for (i = 0; i < width - 2; i++) printf "\342\224\200"
        printf "\342\225\257\n"
    }'
}
