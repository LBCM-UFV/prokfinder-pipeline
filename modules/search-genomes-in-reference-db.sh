#!/usr/bin/env bash
#
# search-genomes-in-reference-db.sh - Prokfinder module 1: genome search in the reference database
#
# Reads a query file (genome-selection-query.txt, written by "main-prokfinder.sh search-genomes") and selects, in
# the NCBI tables, the genome assemblies that satisfy the selection expression. Each filter is one option of the
# command line (several values of the same option = OR); the filters are combined by the expression, with AND, OR
# and parentheses (AND is evaluated before OR). The filters can use the metadata of NCBI, the phenotypic traits of
# BacDive and the taxonomy of GTDB:
#
#   BacDive -> the BacDive table used has one row per species (the strains of the same current NCBI species merged,
#              see normalize-ncbi-taxids.sh and download-reference-db-bacdive.sh). The species is the lowest level of
#              the mapping: a row is linked to the assemblies whose NCBI_UPDATED_TAXID is that species (a TaxID below
#              species is already collapsed to its species by the normalization); an assembly whose NCBI_UPDATED_RANK is
#              above species is not linked. NCBI_SPECIES_IN_BACDIVE tells whether the species of the assembly (or, above
#              species, any species below its TaxID) has a row.
#   GTDB    -> the GTDB lineage of the assembly (GTDB lists each genome under only one of its GenBank/RefSeq
#              accessions, so the accession number without prefix is used)
#   NCBI    -> every assembly of the NCBI table (GenBank by default) is checked against every filter, and the
#              expression decides whether it is selected
#
# QUERY FILE (TAB-separated; empty lines and lines starting with "#" are ignored):
#   ASSEMBLY_SOURCE <TAB> genbank|refseq                 NCBI table that is searched (default: genbank)
#   FILTER <TAB> <id> <TAB> <KEY> <TAB> <value>          one line per value; lines with the same id are one filter
#   EXPRESSION <TAB> <id> AND ( <id> OR <id> ) ...       how the filters are combined (default: AND of all filters)
#   FILTER_FLAG <TAB> <id> <TAB> <option>                option that wrote the filter (shown in the errors)
#   FILTER_ERROR <TAB> <id> <TAB> <KEY> <TAB> <value> <TAB> <error>   a filter that could not be read (e.g., list
#                                                        file not found)
#   FORCE_SEARCH <TAB> yes                               invalid values and filters are ignored (the search goes on
#                                                        with the valid ones); otherwise they stop the search.
#                                                        Both ways, they are listed in the file of --errors-file
#
#   KEY (values of the same filter combined with OR)
#     ACCESSION         GCA_/GCF_ accession with version, matched whole: GCA_ only in the GenBank table, GCF_ only
#                       in the RefSeq table (an accession of the other table is not selected, with a warning)
#     ISOLATION_SOURCE  extended regular expression (POSIX ERE; a plain text is one too) found in the isolation
#                       source (case-insensitive)
#     TAXID             NCBI TaxID of any rank: the assemblies whose current TaxID (<source>-taxid-status.tsv) is that
#                       TaxID or one of its descendants in the NCBI taxonomy (nodes.dmp). A TaxID below species rank
#                       (strain, subspecies...) is replaced by its species, with a warning
#     TAXON_NAME        name of an NCBI taxon (any rank), converted to its TaxID with "taxonkit name2taxid" (Bacteria
#                       and Archaea only); then the same as TAXID. A name without TaxID is an invalid value
#     TAXON_NAME_LIST   the same, from a list file (its first line is a header when it is not a taxon)
#     ASSEMBLY_LEVEL    contig, scaffold, chromosome or complete (complete genome), as in the NCBI assembly level
#     GTDB_TAXON        name of a taxon of the GTDB lineage, case-insensitive: with the rank prefix of GTDB
#                       ("g__Thermus", "s__Thermus aquaticus"), only that rank; without it ("Thermus"), any rank.
#                       A name that is not in the GTDB tables is an invalid value
#     GTDB_TAXON_LIST   the same, from a list file (its first line is a header when it is not a GTDB taxon)
#     BACDIVE_CLASS     <trait>=<class>[,<class>...]: at least one of the classes was recorded for the species (its
#                       column <trait>_<class> is greater than 0)
#   KEY (single value)
#     GENOME_TYPE       isolate_genome or mag
#     GC                <min>:<max> GC content (%) of the assembly (either side may be empty)
#     GENOME_SIZE       <min>:<max> total sequence length of the assembly, in Mb (either side may be empty)
#     BACDIVE_RANGE     <column>=<min>:<max>: the value of the species (mean of its strains) is inside the range
#
# Usage:
#   search-genomes-in-reference-db.sh -q <query_file> --validate-only [--gtdb-dir <dir>] [--taxdump-dir <dir>]
#   search-genomes-in-reference-db.sh -q <query_file> -r <reference_db_dir> -o <selected_metadata.tsv>
#
# Output: <selected_metadata.tsv>, one row per selected assembly: NCBI columns, NCBI_TAXID_STATUS, NCBI_UPDATED_TAXID,
# NCBI_UPDATED_RANK, NCBI_UPDATED_ORGANISM_NAME (the normalized NCBI TaxID) and NCBI_SPECIES_IN_BACDIVE (TRUE/FALSE),
# one SELECTED_BY_* column (TRUE/FALSE) per filter, the *_MATCH columns (values that matched each filter with several
# values, e.g. ISOLATION_SOURCE_KEYWORD_MATCH) and the BACDIVE_* columns.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

usage() {
    cat << EOF
Usage: $(basename "$0") -q <query_file> [-r <reference_db_dir> -o <output_tsv>] [--validate-only]

  -q <file>             Query file (see the header of this script for the format)
  -r <dir>              Reference databases folder (~/prokfinder-refdb)
  -o <file>             Output table with the selected genome assemblies
  --validate-only       Only check the query file (no reference table is read)
  --gtdb-dir <dir>      GTDB reference folder used to check the GTDB taxon names with --validate-only (when it is
                        not given or not installed, the names are checked during the search)
  --taxdump-dir <dir>   NCBI taxdump used to check the taxon names with --validate-only (when it is not given
                        or has no names.dmp, the names are checked during the search)
  --errors-file <file>  TSV file where the invalid values and filters are listed (removed when there is none)
  -h                    Show this help message
EOF
    exit "${1:-1}"
}

QUERY_FILE=""
REF_DIR=""
OUTPUT_TSV=""
GTDB_CHECK_DIR=""
TAXDUMP_DIR=""
ERRORS_FILE=""
VALIDATE_ONLY=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -q) QUERY_FILE="$2"; shift 2 ;;
        -r) REF_DIR="${2%/}"; shift 2 ;;
        -o) OUTPUT_TSV="$2"; shift 2 ;;
        --validate-only) VALIDATE_ONLY=1; shift ;;
        --gtdb-dir) GTDB_CHECK_DIR="${2%/}"; shift 2 ;;
        --taxdump-dir) TAXDUMP_DIR="${2%/}"; shift 2 ;;
        --errors-file) ERRORS_FILE="$2"; shift 2 ;;
        -h|--help) usage 0 ;;
        *) log "error" "Invalid option: $1"; usage ;;
    esac
done

if [[ -z "${QUERY_FILE}" || ! -f "${QUERY_FILE}" ]]; then
    die "Query file not found: '${QUERY_FILE}'"
fi
if [[ "${VALIDATE_ONLY}" -eq 0 && ( -z "${REF_DIR}" || -z "${OUTPUT_TSV}" ) ]]; then
    log "error" "Options -r and -o are required (unless --validate-only is used)."
    usage
fi

if [[ "${VALIDATE_ONLY}" -eq 0 ]]; then
    setup_module_log "$(dirname "${OUTPUT_TSV}")/search-genomes-in-reference-db.log"
fi

make_temp_dir WORK_DIR

############ LOCK ################
#   The taxdump and the *-taxid-status.tsv tables are replaced by normalize-ncbi-taxids.sh under an exclusive lock:
#   the search holds the shared lock while it reads them (released before the result is written), so it waits for a
#   normalization in progress and a normalization waits for the searches.

TAXDUMP_LOCKED=0
if [[ "${VALIDATE_ONLY}" -eq 0 ]]; then
    if command -v flock > /dev/null 2>&1; then
        # (an existing lock file is opened for reading: a shared reference database may not be writable)
        if { [[ -f "${REF_DIR}/.taxdump.lock" ]] && exec 9< "${REF_DIR}/.taxdump.lock"; } 2> /dev/null \
            || { exec 9> "${REF_DIR}/.taxdump.lock"; } 2> /dev/null; then
            if ! flock -n -s 9; then
                log "message" "The NCBI TaxIDs of ${REF_DIR} are being normalized by another process; waiting for it..."
                flock -s 9
            fi
            TAXDUMP_LOCKED=1
        else
            log "warning" "Could not open ${REF_DIR}/.taxdump.lock: the search does not wait for a TaxID normalization in progress."
        fi
    else
        log "warning" "flock not found: the search does not wait for a TaxID normalization in progress."
    fi
    # (a normalization removes the checkpoint when it starts and writes it last)
    [[ -f "$(pf_taxid_marker "${REF_DIR}/NCBI")" ]] \
        || die "The NCBI TaxIDs of ${REF_DIR} are not normalized. Run: main-prokfinder.sh setup (or setup --update-taxdump-file)"
fi

# ---------- Traits of the BacDive table that are divided in classes ----------
# Names are the BacDive trait names; each class is the column <trait>_<class> of the BacDive table (the share of the
# strains of the species that recorded it). The traits and classes are defined in lib/common.sh (pf_bacdive_classes),
# where the BacDive module takes them from: the validation and the filtering read from there.
TRAIT_ORDER=("${PF_BACDIVE_CLASS_TRAITS[@]}")

declare -A TRAIT_CLASSES=()
for TRAIT in "${TRAIT_ORDER[@]}"; do
    TRAIT_CLASSES["${TRAIT}"]="$(pf_bacdive_classes "${TRAIT}")"
done

# BacDive columns copied to the selected genomes (as BACDIVE_<COLUMN>): the numeric traits and, of the traits divided in
# classes, one column per class
BACDIVE_ANNOTATION_TRAITS=(temperature_opt temperature_range_min temperature_range_max ph_opt halophily_opt)
for TRAIT in oxygen_tolerance cell_shape gram_stain spore_formation energy_source carbon_source; do
    for CLASS in ${TRAIT_CLASSES[${TRAIT}]}; do
        BACDIVE_ANNOTATION_TRAITS+=("${TRAIT}_${CLASS}")
    done
done
unset TRAIT CLASS

# Prints the class that a user-typed value stands for (case-insensitive, common synonyms accepted).
# Returns 1 (prints nothing) if the value is not a class of the trait.
# Usage: canonical_class <trait> <value>
canonical_class() {
    local TRAIT="$1"
    local VALUE CLASS
    VALUE="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]-]+/_/g')"

    case "${TRAIT}" in
        cell_shape)
            case "${VALUE}" in
                bacillus|bacilli|bacillary|rods|rod_shaped) VALUE="rod" ;;
                cocci|sphere|spherical)                     VALUE="coccus" ;;
                oval|ellipsoid|ellipsoidal|egg_shaped)      VALUE="ovoid" ;;
                vibrio|crescent|comma|bent)                 VALUE="curved" ;;
                helical|spirillum|spirilla)                 VALUE="spiral" ;;
                filamentous|hyphae)                         VALUE="filament" ;;
            esac
            ;;
        oxygen_tolerance)
            case "${VALUE}" in
                aerobic|aerobes|obligate_aerobe)                    VALUE="aerobe" ;;
                anaerobic|anaerobes|obligate_anaerobe)              VALUE="anaerobe" ;;
                microaerophilic|microaerobic|microaerophiles)       VALUE="microaerophile" ;;
                facultative_anaerobe|facultative_aerobe|facultatively_anaerobic) VALUE="facultative" ;;
            esac
            ;;
        gram_stain)
            case "${VALUE}" in
                pos|gram_positive|"+") VALUE="positive" ;;
                neg|gram_negative)     VALUE="negative" ;;
            esac
            ;;
        motility|pigmentation_production|forms_multicellular_complex|spore_formation)
            case "${VALUE}" in
                true|y)  VALUE="yes" ;;
                false|n) VALUE="no" ;;
            esac
            ;;
    esac

    for CLASS in ${TRAIT_CLASSES[${TRAIT}]}; do
        if [[ "${CLASS}" == "${VALUE}" ]]; then
            echo "${CLASS}"
            return 0
        fi
    done
    return 1
}

# Prints what is wrong with a range "<min>:<max>" (numbers; either side may be empty, not both; min <= max), or
# nothing when it is valid
# Usage: range_problem <range>
range_problem() {
    local RANGE="$1"
    local MIN MAX VALUE
    local NUMBER_REGEX='^-?[0-9]+([.][0-9]+)?$'

    if [[ "${RANGE}" != *:* ]]; then
        echo "expected <min>:<max> (e.g., 45:80); either side may be left empty"
        return 0
    fi
    MIN="${RANGE%%:*}"
    MAX="${RANGE#*:}"
    if [[ -z "${MIN}${MAX}" ]]; then
        echo "give at least a minimum or a maximum"
        return 0
    fi
    for VALUE in "${MIN}" "${MAX}"; do
        if [[ -n "${VALUE}" && ! "${VALUE}" =~ ${NUMBER_REGEX} ]]; then
            echo "'${VALUE}' is not a number"
            return 0
        fi
    done
    if [[ -n "${MIN}" && -n "${MAX}" ]] && awk -v a="${MIN}" -v b="${MAX}" 'BEGIN { exit !(a + 0 > b + 0) }'; then
        echo "the minimum is greater than the maximum"
    fi
}


############ READING THE QUERY ################

Q_ASSEMBLY_SOURCE="genbank"
EXPRESSION=""
FORCE_SEARCH=0
F_IDS=()                 # filter ids, in the order of the query file
declare -A F_KEY=()      # id -> key
declare -A F_VALUES=()   # id -> values, one per line
declare -A F_SEEN=()     # id TAB value -> 1
declare -A F_FLAG=()     # id -> option of main-prokfinder.sh that wrote the filter (e.g., --gtdb-taxon)
declare -A F_INVALID=()  # id -> 1 when the whole filter is invalid
ERRORS=()                # <filter id> TAB <value> TAB <error>: every invalid value or filter
ERRORS_WARNED=0          # errors already shown (--force-search)

# Records an invalid value of a filter (or the whole filter, with an empty value)
# Usage: filter_error <id> <value> <error>
filter_error() {
    ERRORS+=("$1"$'\t'"$2"$'\t'"$3")
}

# Registers a filter the first time one of its lines is read
# Usage: register_filter <id> <key>
register_filter() {
    if [[ -z "${F_KEY[$1]:-}" ]]; then
        F_IDS+=("$1")
        F_KEY["$1"]="$2"
        F_VALUES["$1"]=""
    elif [[ "${F_KEY[$1]}" != "$2" ]]; then
        die "Query line ${LINE_NUMBER}: filter $1 has two different keys (${F_KEY[$1]} and $2)."
    fi
}

# Keys whose filter has a single value
SINGLE_VALUE_KEYS=" GENOME_TYPE GC GENOME_SIZE BACDIVE_RANGE BACDIVE_CLASS "

LINE_NUMBER=0
while IFS= read -r LINE || [[ -n "${LINE}" ]]; do
    LINE_NUMBER=$((LINE_NUMBER + 1))
    LINE="${LINE//$'\r'/}"
    if [[ -z "${LINE//[[:space:]]/}" || "${LINE}" =~ ^[[:space:]]*# ]]; then
        continue
    fi
    IFS=$'\t' read -r KIND ID KEY VALUE <<< "${LINE}"
    case "${KIND}" in
        ASSEMBLY_SOURCE)
            Q_ASSEMBLY_SOURCE="${ID,,}"
            if [[ "${Q_ASSEMBLY_SOURCE}" != "genbank" && "${Q_ASSEMBLY_SOURCE}" != "refseq" ]]; then
                die "Invalid assembly source '${ID}'. Must be 'genbank' or 'refseq'."
            fi
            continue
            ;;
        EXPRESSION)
            EXPRESSION="${LINE#*$'\t'}"
            continue
            ;;
        FORCE_SEARCH)
            FORCE_SEARCH=1
            continue
            ;;
        FILTER_FLAG)
            F_FLAG["${ID}"]="${KEY}"
            continue
            ;;
        FILTER_ERROR)
            # A filter that main-prokfinder.sh could not read (e.g., a list file not found): <value> TAB <error>
            register_filter "${ID}" "${KEY}"
            F_INVALID["${ID}"]=1
            filter_error "${ID}" "${VALUE%%$'\t'*}" "${VALUE#*$'\t'}"
            continue
            ;;
        FILTER) ;;
        *) die "Unknown line ${LINE_NUMBER} of the query file: '${LINE}'" ;;
    esac

    if [[ ! "${ID}" =~ ^[A-Za-z0-9_]+$ ]]; then
        die "Query line ${LINE_NUMBER}: invalid filter id '${ID}'."
    fi
    VALUE="${VALUE:-}"
    VALUE="${VALUE#"${VALUE%%[![:space:]]*}"}"
    VALUE="${VALUE%"${VALUE##*[![:space:]]}"}"
    if [[ -z "${VALUE}" ]]; then
        die "Query line ${LINE_NUMBER} (${KEY}) has no value."
    fi
    if [[ -n "${F_KEY[${ID}]:-}" && "${SINGLE_VALUE_KEYS}" == *" ${KEY} "* ]]; then
        die "Query line ${LINE_NUMBER}: filter ${ID} (${KEY}) takes a single value."
    fi
    register_filter "${ID}" "${KEY}"

    # An invalid value is recorded (filter_error) and left out of the filter
    case "${KEY}" in
        ACCESSION)
            VALUE="${VALUE^^}"
            if [[ ! "${VALUE}" =~ ^GC[AF]_[0-9]+[.][0-9]+$ ]]; then
                filter_error "${ID}" "${VALUE}" "invalid accession: GCA_ or GCF_, the number and the version (e.g., GCA_000005845.2)"
                continue
            fi
            ;;
        TAXID)
            if [[ ! "${VALUE}" =~ ^[0-9]+$ ]]; then
                filter_error "${ID}" "${VALUE}" "invalid NCBI TaxID (expected a number)"
                continue
            fi
            ;;
        ASSEMBLY_LEVEL)
            case "${VALUE,,}" in
                contig)                                            VALUE="Contig" ;;
                scaffold)                                          VALUE="Scaffold" ;;
                chromosome)                                        VALUE="Chromosome" ;;
                complete|complete_genome|complete-genome|"complete genome") VALUE="Complete Genome" ;;
                *)
                    filter_error "${ID}" "${VALUE}" "invalid assembly level (contig, scaffold, chromosome or complete)"
                    continue
                    ;;
            esac
            ;;
        ISOLATION_SOURCE)
            # an extended regular expression (a plain text is one too); bash returns 2 when it does not compile
            RC=0
            [[ "" =~ ${VALUE,,} ]] || RC=$?
            if [[ "${RC}" -eq 2 ]]; then
                filter_error "${ID}" "${VALUE}" "invalid regular expression (write \\ before ( ) [ ] . * + ? | ^ \$ to search them as text)"
                continue
            fi
            ;;
        TAXON_NAME|TAXON_NAME_LIST|GTDB_TAXON|GTDB_TAXON_LIST) ;;
        GENOME_TYPE)
            VALUE="${VALUE,,}"
            if [[ "${VALUE}" != "isolate_genome" && "${VALUE}" != "mag" ]]; then
                filter_error "${ID}" "${VALUE}" "invalid genome type (isolate_genome or mag)"
                continue
            fi
            ;;
        GC|GENOME_SIZE)
            PROBLEM="$(range_problem "${VALUE}")"
            if [[ -n "${PROBLEM}" ]]; then
                filter_error "${ID}" "${VALUE}" "invalid range: ${PROBLEM}"
                continue
            fi
            ;;
        BACDIVE_RANGE)
            if [[ "${VALUE}" != *=* || -z "${VALUE%%=*}" ]]; then
                die "Invalid BACDIVE_RANGE '${VALUE}'. Expected <column>=<min>:<max>."
            fi
            PROBLEM="$(range_problem "${VALUE#*=}")"
            if [[ -n "${PROBLEM}" ]]; then
                filter_error "${ID}" "${VALUE#*=}" "invalid range: ${PROBLEM}"
                continue
            fi
            ;;
        BACDIVE_CLASS)
            if [[ "${VALUE}" != *=* ]]; then
                die "Invalid BACDIVE_CLASS '${VALUE}'. Expected <trait>=<class>[,<class>...] (e.g., gram_stain=negative)."
            fi
            TRAIT="$(printf '%s' "${VALUE%%=*}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
            if [[ ! "${TRAIT}" =~ ^[a-z0-9_]+$ || -z "${TRAIT_CLASSES[${TRAIT}]:-}" ]]; then
                die "Unknown trait '${VALUE%%=*}'. Traits divided in classes: ${TRAIT_ORDER[*]}."
            fi
            CLASS_LIST=""
            IFS=',' read -ra ITEMS <<< "${VALUE#*=}"
            for ITEM in "${ITEMS[@]}"; do
                if [[ -z "${ITEM//[[:space:]]/}" ]]; then
                    continue
                fi
                if ! CANON="$(canonical_class "${TRAIT}" "${ITEM}")"; then
                    filter_error "${ID}" "${ITEM}" "invalid class for ${TRAIT} (valid: ${TRAIT_CLASSES[${TRAIT}]// /, })"
                    continue
                fi
                case ",${CLASS_LIST}," in
                    *",${CANON},"*) ;;
                    *) CLASS_LIST="${CLASS_LIST:+${CLASS_LIST},}${CANON}" ;;
                esac
            done
            [[ -n "${CLASS_LIST}" ]] || continue
            VALUE="${TRAIT}=${CLASS_LIST}"
            ;;
        *)
            die "Unknown key '${KEY}' in line ${LINE_NUMBER} of the query file."
            ;;
    esac

    # A value repeated in the same filter (e.g., one line per strain of the same species) is kept once
    [[ -z "${F_SEEN[${ID}$'\t'${VALUE}]:-}" ]] || continue
    F_SEEN["${ID}"$'\t'"${VALUE}"]=1
    F_VALUES["${ID}"]+="${VALUE}"$'\n'
done < "${QUERY_FILE}"

if [[ "${#F_IDS[@]}" -eq 0 ]]; then
    die "The query has no selection filter."
fi

############ INVALID FILTERS ################
#   Every invalid value or filter is listed in the errors file (--errors-file). Without FORCE_SEARCH the search stops;
#   with it, the invalid values are left out, the filters without any valid value are removed (from the expression
#   too) and the search goes on with the valid ones.

# Writes the errors file and stops, or (FORCE_SEARCH) warns and removes the filters without valid values
check_filter_errors() {
    local ID LINE SHOWN=0
    local -a KEPT=()
    for ID in "${F_IDS[@]}"; do
        if [[ -z "${F_VALUES[${ID}]}" && -z "${F_INVALID[${ID}]:-}" ]]; then
            F_INVALID["${ID}"]=1
            filter_error "${ID}" "" "the filter has no valid value"
        fi
    done

    if [[ "${#ERRORS[@]}" -eq 0 ]]; then
        [[ -z "${ERRORS_FILE}" ]] || rm -f "${ERRORS_FILE}"
        return 0
    fi
    if [[ -n "${ERRORS_FILE}" ]]; then
        mkdir -p "$(dirname "${ERRORS_FILE}")"
        {
            printf 'FILTER\tOPTION\tVALUE\tERROR\n'
            for LINE in "${ERRORS[@]}"; do
                ID="${LINE%%$'\t'*}"
                printf '%s\t%s\t%s\n' "${ID}" "${F_FLAG[${ID}]:-${F_KEY[${ID}]}}" "${LINE#*$'\t'}"
            done
        } > "${ERRORS_FILE}"
    fi

    # Shows at most 10 errors (all of them are in the errors file)
    show_error() {
        local REC="${ERRORS[$1]}" ID VALUE
        ID="${REC%%$'\t'*}"; REC="${REC#*$'\t'}"; VALUE="${REC%%$'\t'*}"
        log "$2" "  ${ID} ${F_FLAG[${ID}]:-${F_KEY[${ID}]}}${VALUE:+ '${VALUE}'}: ${REC#*$'\t'}"
    }

    if [[ "${FORCE_SEARCH}" -eq 0 ]]; then
        log "error" "Invalid selection filters:"
        for (( I = 0; I < ${#ERRORS[@]} && I < 10; I++ )); do show_error "${I}" error; done
        [[ "${#ERRORS[@]}" -le 10 ]] || log "error" "  ... and $(( ${#ERRORS[@]} - 10 )) more"
        die "${#ERRORS[@]} invalid value(s) or filter(s)${ERRORS_FILE:+, all listed in ${ERRORS_FILE}}. Fix them, or use search-genomes --force-search to ignore them and search with the valid filters."
    fi

    # --force-search: the errors are shown once (not in the check made before the run, to avoid showing them twice)
    if [[ "${VALIDATE_ONLY}" -eq 0 && "${ERRORS_WARNED}" -lt "${#ERRORS[@]}" ]]; then
        log "warning" "--force-search: invalid values and filters ignored${ERRORS_FILE:+ (all listed in ${ERRORS_FILE})}:"
        for (( I = ERRORS_WARNED; I < ${#ERRORS[@]} && SHOWN < 10; I++, SHOWN++ )); do show_error "${I}" warning; done
        [[ "$(( ${#ERRORS[@]} - ERRORS_WARNED ))" -le 10 ]] || log "warning" "  ... and $(( ${#ERRORS[@]} - ERRORS_WARNED - 10 )) more"
    fi
    ERRORS_WARNED="${#ERRORS[@]}"

    for ID in "${F_IDS[@]}"; do
        if [[ -n "${F_INVALID[${ID}]:-}" ]]; then
            [[ "${VALIDATE_ONLY}" -eq 1 ]] || log "warning" "Filter ${ID} (${F_FLAG[${ID}]:-${F_KEY[${ID}]}}) removed from the search: it has no valid value."
        else
            KEPT+=("${ID}")
        fi
    done
    [[ "${#KEPT[@]}" -gt 0 ]] || die "No valid selection filter is left (every filter is invalid${ERRORS_FILE:+; see ${ERRORS_FILE}})."
    F_IDS=("${KEPT[@]}")
}

############ TAXON NAMES -> NCBI TAXIDS ################

# Converts every TAXON_NAME / TAXON_NAME_LIST name into NCBI TaxIDs of Bacteria or Archaea (taxonkit name2taxid). A
# name without such TaxID is an invalid value (filter_error). A name with several TaxIDs (homonyms) keeps all of them.
# Usage: resolve_taxon_names <taxdump_dir> <output: taxid TAB name>
resolve_taxon_names() {
    local TAXDUMP="$1"
    local OUT="$2"
    local -a ARGS=()
    local ID FIRST NAME
    if [[ -n "${TAXDUMP}" ]]; then
        ARGS=(--data-dir "${TAXDUMP}")
    fi

    for ID in "${F_IDS[@]}"; do
        if [[ "${F_KEY[${ID}]}" == TAXON_NAME* ]]; then
            printf '%s' "${F_VALUES[${ID}]}"
        fi
    done | sort -u > "${WORK_DIR}/taxon_names.txt"

    # name2taxid prints "<name> <TAB> <taxid>" (one line per TaxID; empty TaxID when the name is unknown)
    taxonkit name2taxid ${ARGS[@]+"${ARGS[@]}"} < "${WORK_DIR}/taxon_names.txt" > "${WORK_DIR}/name2taxid.tsv" 2> "${WORK_DIR}/name2taxid.err" \
        || die "taxonkit name2taxid failed: $(awk 'NR <= 3' "${WORK_DIR}/name2taxid.err" | tr '\n' ' ')"
    awk -F'\t' '$2 ~ /^[0-9]+$/ { print $2 }' "${WORK_DIR}/name2taxid.tsv" | sort -u \
        | taxonkit lineage -t ${ARGS[@]+"${ARGS[@]}"} > "${WORK_DIR}/name2taxid.lineage" 2>> "${WORK_DIR}/name2taxid.err" \
        || die "taxonkit lineage failed: $(awk 'NR <= 3' "${WORK_DIR}/name2taxid.err" | tr '\n' ' ')"

    # Only TaxIDs whose lineage contains Bacteria (2) or Archaea (2157)
    awk -F'\t' -v OFS='\t' -v lineage="${WORK_DIR}/name2taxid.lineage" '
        BEGIN { while ((getline line < lineage) > 0) { split(line, f, "\t"); if ((";" f[3] ";") ~ /;(2|2157);/) prok[f[1]] = 1 } }
        $2 ~ /^[0-9]+$/ && ($2 in prok) { print $2, $1 }
    ' "${WORK_DIR}/name2taxid.tsv" | sort -u > "${OUT}"

    for ID in "${F_IDS[@]}"; do
        [[ "${F_KEY[${ID}]}" == TAXON_NAME* ]] || continue
        # The first line of a list file (-N) that is not a taxon is its header (e.g., "Species Name"): it is skipped
        FIRST="${F_VALUES[${ID}]%%$'\n'*}"
        if [[ "${F_KEY[${ID}]}" == "TAXON_NAME_LIST" ]] \
            && ! awk -F'\t' -v name="${FIRST,,}" 'tolower($2) == name { found = 1 } END { exit !found }' "${OUT}"; then
            if [[ "${VALIDATE_ONLY}" -eq 0 ]]; then
                log "warning" "First line of the taxon list of filter ${ID} ('${FIRST}') is not a Bacteria/Archaea taxon: taken as a header and skipped."
            fi
            F_VALUES["${ID}"]="${F_VALUES[${ID}]#*$'\n'}"
        fi
        # The other names without a Bacteria/Archaea TaxID are invalid values
        while IFS= read -r NAME; do
            filter_error "${ID}" "${NAME}" "taxon name not found in the NCBI taxonomy of Bacteria and Archaea (check the spelling)"
        done < <(printf '%s' "${F_VALUES[${ID}]}" | awk -F'\t' -v found="${OUT}" '
            BEGIN { while ((getline line < found) > 0) { split(line, f, "\t"); ok[tolower(f[2])] = 1 } }
            NF && !(tolower($0) in ok)')
        F_VALUES["${ID}"]="$(printf '%s' "${F_VALUES[${ID}]}" | awk -F'\t' -v found="${OUT}" '
            BEGIN { while ((getline line < found) > 0) { split(line, f, "\t"); ok[tolower(f[2])] = 1 } }
            NF && (tolower($0) in ok)')"
        [[ -z "${F_VALUES[${ID}]}" ]] || F_VALUES["${ID}"]+=$'\n'
    done
}

HAS_TAXON_NAME=0
for ID in "${F_IDS[@]}"; do
    [[ "${F_KEY[${ID}]}" == TAXON_NAME* ]] && HAS_TAXON_NAME=1
done

# The taxon names are checked with the taxdump of the reference databases (never the global ~/.taxonkit one); before
# the run (--validate-only), only if taxonkit and the taxdump are available here (otherwise they are checked during
# the search)
if [[ "${HAS_TAXON_NAME}" -eq 1 ]]; then
    TAXDUMP_IN_USE=""
    RESOLVE=0
    if [[ "${VALIDATE_ONLY}" -eq 1 ]]; then
        if command -v taxonkit >/dev/null 2>&1 && [[ -n "${TAXDUMP_DIR}" && -f "${TAXDUMP_DIR}/names.dmp" ]]; then
            TAXDUMP_IN_USE="${TAXDUMP_DIR}"; RESOLVE=1
        fi
    else
        require_programs taxonkit
        TAXDUMP_IN_USE="$(pf_ncbi_taxdump_dir "${REF_DIR}/NCBI")"
        [[ -f "${TAXDUMP_IN_USE}/names.dmp" ]] \
            || die "NCBI taxdump not found in ${TAXDUMP_IN_USE}. Run: main-prokfinder.sh setup (or setup --update-taxdump-file)"
        RESOLVE=1
    fi
    if [[ "${RESOLVE}" -eq 1 ]]; then
        resolve_taxon_names "${TAXDUMP_IN_USE}" "${WORK_DIR}/taxon_names.tsv"
        if [[ "${VALIDATE_ONLY}" -eq 0 ]]; then
            log "message" "Taxon names converted to NCBI TaxIDs: $(cut -f2 "${WORK_DIR}/taxon_names.tsv" | sort -u | wc -l) names, $(cut -f1 "${WORK_DIR}/taxon_names.tsv" | sort -u | wc -l) TaxIDs"
        fi
    fi
fi

############ GTDB TAXON NAMES ################
#   Every GTDB taxon name must be in the GTDB tables: a name that is not (e.g., "g_Thermus" with one underscore) is an
#   invalid value. The first line of a list file (--gtdb-taxon-file) that is not a GTDB taxon is its header.

# Writes the GTDB taxon names (lower case, as written by the user) of <names> that are in the GTDB tables
# Usage: found_gtdb_taxa <gtdb_dir> <names> <output>
found_gtdb_taxa() {
    local -a TABLES=()
    local DOMAIN
    for DOMAIN in "${PF_DOMAINS[@]}"; do
        TABLES+=("$(pf_gtdb_taxonomy_table "$1" "${DOMAIN}")")
    done
    awk -F'\t' -v names="$2" '
        BEGIN {
            letter["GTDB_DOMAIN"] = "d"; letter["GTDB_PHYLUM"] = "p"; letter["GTDB_CLASS"] = "c"; letter["GTDB_ORDER"] = "o"
            letter["GTDB_FAMILY"] = "f"; letter["GTDB_GENUS"] = "g"; letter["GTDB_SPECIES"] = "s"
            while ((getline v < names) > 0) { v = tolower(v); want[v] = 1; if (v ~ /^[dpcofgs]__/) want_ranked[substr(v, 4)] = 1; else want_any[v] = 1 }
            close(names)
        }
        FNR == 1 { delete rank_col; for (i = 1; i <= NF; i++) if ($i in letter) rank_col[i] = letter[$i]; next }
        {
            for (i in rank_col) {
                v = tolower($i)
                if (v in want_any) found[v] = 1
                if (v in want_ranked) found[rank_col[i] "__" v] = 1
            }
        }
        END { for (v in found) print v }
    ' "${TABLES[@]}" > "$3"
}

HAS_GTDB_TAXON=0
for ID in "${F_IDS[@]}"; do
    [[ "${F_KEY[${ID}]}" == GTDB_TAXON* ]] && HAS_GTDB_TAXON=1
done

# Before the run (--validate-only), only when the GTDB tables are installed (otherwise they are checked in the search)
GTDB_NAMES_DIR=""
if [[ "${VALIDATE_ONLY}" -eq 1 ]]; then
    GTDB_NAMES_DIR="${GTDB_CHECK_DIR}"
else
    GTDB_NAMES_DIR="${REF_DIR}/GTDB"
fi
if [[ "${HAS_GTDB_TAXON}" -eq 1 && -n "${GTDB_NAMES_DIR}" && -f "$(pf_gtdb_taxonomy_table "${GTDB_NAMES_DIR}" BACTERIA)" ]]; then
    for ID in "${F_IDS[@]}"; do
        [[ "${F_KEY[${ID}]}" != GTDB_TAXON* ]] || printf '%s' "${F_VALUES[${ID}]}"
    done | sort -u > "${WORK_DIR}/gtdb_names.txt"
    found_gtdb_taxa "${GTDB_NAMES_DIR}" "${WORK_DIR}/gtdb_names.txt" "${WORK_DIR}/gtdb_names_found.txt"

    for ID in "${F_IDS[@]}"; do
        [[ "${F_KEY[${ID}]}" == GTDB_TAXON* ]] || continue
        # The first line of a list file that is not a GTDB taxon is its header (e.g., "taxon"): it is skipped
        FIRST="${F_VALUES[${ID}]%%$'\n'*}"
        if [[ "${F_KEY[${ID}]}" == "GTDB_TAXON_LIST" ]] && ! grep -qxF -- "${FIRST,,}" "${WORK_DIR}/gtdb_names_found.txt"; then
            if [[ "${VALIDATE_ONLY}" -eq 0 ]]; then
                log "warning" "First line of the GTDB taxon list of filter ${ID} ('${FIRST}') is not a GTDB taxon: taken as a header and skipped."
            fi
            F_VALUES["${ID}"]="${F_VALUES[${ID}]#*$'\n'}"
        fi
        # The other names that are not in the GTDB tables are invalid values
        while IFS= read -r NAME; do
            filter_error "${ID}" "${NAME}" "taxon not found in the GTDB taxonomy (write it as in GTDB, with or without the rank prefix of two underscores: g__Thermus, s__Thermus aquaticus or Thermus)"
        done < <(printf '%s' "${F_VALUES[${ID}]}" | awk -v found="${WORK_DIR}/gtdb_names_found.txt" '
            BEGIN { while ((getline line < found) > 0) ok[line] = 1 }
            NF && !(tolower($0) in ok)')
        F_VALUES["${ID}"]="$(printf '%s' "${F_VALUES[${ID}]}" | awk -v found="${WORK_DIR}/gtdb_names_found.txt" '
            BEGIN { while ((getline line < found) > 0) ok[line] = 1 }
            NF && (tolower($0) in ok)')"
        [[ -z "${F_VALUES[${ID}]}" ]] || F_VALUES["${ID}"]+=$'\n'
    done
fi

# Every invalid value and filter is known now: they are listed together (and stop the search or are ignored)
check_filter_errors

############ SELECTION EXPRESSION ################
#   The expression is converted to postfix notation (shunting-yard): AND is evaluated before OR, and parentheses
#   group filters. Every filter must appear in the expression.

if [[ -z "${EXPRESSION//[[:space:]]/}" ]]; then
    EXPRESSION="$(printf '%s\n' "${F_IDS[@]}" | paste -sd ' ' | sed 's/ / AND /g')"
fi
# Usage: expression_error <message>
expression_error() {
    die "Invalid selection expression '${EXPRESSION}': $1"
}
declare -A F_INDEX=()
for (( I = 0; I < ${#F_IDS[@]}; I++ )); do
    F_INDEX["${F_IDS[$I]}"]=$((I + 1))
done
read -ra TOKENS <<< "${EXPRESSION//(/ ( }"
TOKENS_STR="${TOKENS[*]}"
read -ra TOKENS <<< "${TOKENS_STR//)/ ) }"

# Filters removed by --force-search leave the expression with their nearest AND (or, without one, their nearest
# OR): "A AND X OR B" -> "A OR B", "A OR X AND B" -> "A OR B"; a group left empty, "( X )", is removed the same way
if [[ "${#F_INVALID[@]}" -gt 0 ]]; then
    for (( I = 0; I < ${#TOKENS[@]}; I++ )); do
        case "${TOKENS[$I]^^}" in
            AND|OR|"("|")") TOKENS[I]="${TOKENS[$I]^^}" ;;
            *) [[ -z "${F_INVALID[${TOKENS[$I]}]:-}" ]] || TOKENS[I]="_" ;;
        esac
    done
    CHANGED=1
    while [[ "${CHANGED}" -eq 1 ]]; do
        CHANGED=0
        N="${#TOKENS[@]}"
        for (( I = 0; I < N; I++ )); do
            [[ "${TOKENS[$I]}" == "_" ]] || continue
            L=$((I - 1)); R=$((I + 1))
            LT=""; RT=""
            (( L >= 0 )) && LT="${TOKENS[$L]}"
            (( R < N )) && RT="${TOKENS[$R]}"
            if [[ "${LT}" == "(" && "${RT}" == ")" ]]; then
                TOKENS=("${TOKENS[@]:0:L}" "_" "${TOKENS[@]:R+1}")
            elif [[ "${LT}" == "AND" ]]; then
                TOKENS=("${TOKENS[@]:0:L}" "${TOKENS[@]:I+1}")
            elif [[ "${RT}" == "AND" ]]; then
                TOKENS=("${TOKENS[@]:0:I}" "${TOKENS[@]:R+1}")
            elif [[ "${LT}" == "OR" ]]; then
                TOKENS=("${TOKENS[@]:0:L}" "${TOKENS[@]:I+1}")
            elif [[ "${RT}" == "OR" ]]; then
                TOKENS=("${TOKENS[@]:0:I}" "${TOKENS[@]:R+1}")
            else
                TOKENS=("${TOKENS[@]:0:I}" "${TOKENS[@]:I+1}")
            fi
            CHANGED=1
            break
        done
    done
    EXPRESSION="${TOKENS[*]}"
    [[ "${VALIDATE_ONLY}" -eq 1 ]] || log "warning" "--force-search: selection expression without the removed filters: ${EXPRESSION}"
fi

declare -A F_USED=()
RPN=()
STACK=()
PREV="start"   # start | operand | operator | open | close
for TOKEN in ${TOKENS[@]+"${TOKENS[@]}"}; do
    case "${TOKEN^^}" in
        AND|OR)
            [[ "${PREV}" == "operand" || "${PREV}" == "close" ]] || expression_error "${TOKEN^^} must be between two filters."
            while [[ "${#STACK[@]}" -gt 0 ]]; do
                TOP="${STACK[-1]}"
                if [[ "${TOP}" == "AND" || ( "${TOP}" == "OR" && "${TOKEN^^}" == "OR" ) ]]; then
                    RPN+=("${TOP}"); unset 'STACK[-1]'
                else
                    break
                fi
            done
            STACK+=("${TOKEN^^}")
            PREV="operator"
            ;;
        "(")
            [[ "${PREV}" == "start" || "${PREV}" == "operator" || "${PREV}" == "open" ]] || expression_error "AND or OR is missing before '('."
            STACK+=("(")
            PREV="open"
            ;;
        ")")
            [[ "${PREV}" == "operand" || "${PREV}" == "close" ]] || expression_error "')' must close a group of filters."
            FOUND=0
            while [[ "${#STACK[@]}" -gt 0 ]]; do
                TOP="${STACK[-1]}"; unset 'STACK[-1]'
                if [[ "${TOP}" == "(" ]]; then FOUND=1; break; fi
                RPN+=("${TOP}")
            done
            [[ "${FOUND}" -eq 1 ]] || expression_error "')' without '('."
            PREV="close"
            ;;
        *)
            [[ -n "${F_INDEX[${TOKEN}]:-}" ]] || expression_error "unknown filter '${TOKEN}'."
            [[ "${PREV}" == "start" || "${PREV}" == "operator" || "${PREV}" == "open" ]] || expression_error "AND or OR is missing before ${TOKEN}."
            RPN+=("${F_INDEX[${TOKEN}]}")
            F_USED["${TOKEN}"]=1
            PREV="operand"
            ;;
    esac
done
[[ "${PREV}" == "operand" || "${PREV}" == "close" ]] || expression_error "it must end with a filter or ')'."
while [[ "${#STACK[@]}" -gt 0 ]]; do
    TOP="${STACK[-1]}"; unset 'STACK[-1]'
    [[ "${TOP}" != "(" ]] || expression_error "'(' without ')'."
    RPN+=("${TOP}")
done
for ID in "${F_IDS[@]}"; do
    [[ -n "${F_USED[${ID}]:-}" ]] || expression_error "filter ${ID} is not used."
done

if [[ "${VALIDATE_ONLY}" -eq 1 ]]; then
    exit 0
fi

############ REFERENCE TABLES ################

NCBI_DIR="${REF_DIR}/NCBI"
BACDIVE_TSV="$(pf_bacdive_species_table "${REF_DIR}/BACDIVE")"

NCBI_NODES="$(pf_ncbi_taxdump_dir "${NCBI_DIR}")/nodes.dmp"
NCBI_TABLES=()
NCBI_STATUS_TABLES=()
for DOMAIN in "${PF_DOMAINS[@]}"; do
    TABLE="$(pf_ncbi_metadata_table "${NCBI_DIR}" "${DOMAIN}" "${Q_ASSEMBLY_SOURCE}")"
    if [[ ! -f "${TABLE}" ]]; then
        die "NCBI table not found: ${TABLE}. Install the reference databases with: main-prokfinder.sh setup"
    fi
    if [[ "${#NCBI_TABLES[@]}" -gt 0 && "$(head -n 1 "${TABLE}")" != "$(head -n 1 "${NCBI_TABLES[0]}")" ]]; then
        die "The columns of ${TABLE} differ from those of ${NCBI_TABLES[0]}."
    fi
    NCBI_TABLES+=("${TABLE}")
    # normalized NCBI TaxID of each assembly (normalize-ncbi-taxids.sh)
    STATUS_TABLE="$(pf_ncbi_taxid_status_table "${NCBI_DIR}" "${DOMAIN}" "${Q_ASSEMBLY_SOURCE}")"
    [[ -f "${STATUS_TABLE}" ]] \
        || die "The normalized NCBI TaxIDs were not found: ${STATUS_TABLE}. Run: main-prokfinder.sh setup (or setup --update-taxdump-file)"
    NCBI_STATUS_TABLES+=("${STATUS_TABLE}")
done
[[ -f "${NCBI_NODES}" ]] || die "NCBI taxdump not found: ${NCBI_NODES}. Run: main-prokfinder.sh setup (or setup --update-taxdump-file)"
NCBI_HEADER_FILE="${NCBI_TABLES[0]}"
NCBI_STATUS_LIST="$(IFS=,; echo "${NCBI_STATUS_TABLES[*]}")"
# (the BacDive table has one row per current species: normalize-ncbi-taxids.sh writes it)

# Common awk functions
AWK_LIB='
function is_empty(x)  { return x == "" || x == "NULL" || x == "NA" }
function is_number(x) { return x ~ /^[+-]?[0-9]+([.][0-9]+)?$/ }
# 1 if at least one of the values of the cell (separated by ";", ":" or "|") is inside [lo, hi]; empty bound = open
function any_in_range(x, lo, hi,   parts, n, i) {
    n = split(x, parts, /[;:|]/)
    for (i = 1; i <= n; i++) {
        if (!is_number(parts[i])) continue
        if (lo != "" && parts[i] + 0 < lo + 0) continue
        if (hi != "" && parts[i] + 0 > hi + 0) continue
        return 1
    }
    return 0
}
# GCA_000005845.2 -> 000005845.2 (GenBank and RefSeq assemblies of the same genome share the number)
function acc_number(acc,   a) { a = acc; sub(/^GC[AF]_/, "", a); return a }
function acc_base(acc,   a) { a = acc_number(acc); sub(/[.][0-9]+$/, "", a); return a }
'

# Name of a BacDive trait in the SELECTED_BY columns (the option of main-prokfinder.sh)
bacdive_trait_name() {
    case "${1,,}" in
        temperature_opt)        echo "OPT_TEMP" ;;
        ph_opt)                 echo "OPT_PH" ;;
        halophily_opt)          echo "OPT_SALT" ;;
        temperature_preference) echo "TEMP_GROWTH" ;;
        ph_preference)          echo "PH_GROWTH" ;;
        halophily_preference)   echo "SALT_GROWTH" ;;
        cell_shape)             echo "CELL_SHAPE" ;;
        oxygen_tolerance)       echo "OXYGEN" ;;
        *)                      echo "${1^^}" ;;
    esac
}

# Columns written for each filter, in the order of the filters:
#   flags with a single option  SELECTED_BY_<FLAG>-<OPTION>    e.g. SELECTED_BY_GENOME_TYPE-ISOLATE-GENOME
#   numeric flags               SELECTED_BY_<FLAG>-<RANGE>     e.g. SELECTED_BY_OPT_TEMP-45:80
#   flags with several values   SELECTED_BY_<FLAG> + a column with the values that matched (separated by ";")
# A name used twice (the same option given twice) gets a number (_2, _3...).
FILTERS_SPEC="${WORK_DIR}/filters.tsv"     # <index> <key> <arg1> <arg2> <SELECTED_BY name> <match name> <label>
FILTER_VALUES="${WORK_DIR}/filter_values.tsv"   # <index> <value> (filters with a list of values)
: > "${FILTERS_SPEC}"
: > "${FILTER_VALUES}"
declare -A USED_NAME=()
BD_FILTERS=()      # indexes of the BacDive filters, in order
GTDB_FILTERS=()    # indexes of the GTDB filters
for (( I = 0; I < ${#F_IDS[@]}; I++ )); do
    ID="${F_IDS[$I]}"
    IDX=$((I + 1))
    KEY="${F_KEY[${ID}]}"
    VALUES="${F_VALUES[${ID}]%$'\n'}"
    ARG1=""; ARG2=""; MATCH=""
    case "${KEY}" in
        ACCESSION)        NAME="ACCESSION";        LABEL="accession" ;;
        ISOLATION_SOURCE) NAME="ISOLATION_SOURCE"; MATCH="ISOLATION_SOURCE_KEYWORD_MATCH"; LABEL="isolation source" ;;
        TAXID)            NAME="TAXID";            MATCH="TAXID_MATCH";            LABEL="NCBI TaxID" ;;
        TAXON_NAME)       NAME="NCBI_TAXON";       MATCH="NCBI_TAXON_MATCH";       LABEL="NCBI taxon" ;;
        TAXON_NAME_LIST)  NAME="NCBI_TAXON_LIST";  MATCH="NCBI_TAXON_LIST_MATCH";  LABEL="NCBI taxon list" ;;
        ASSEMBLY_LEVEL)   NAME="ASSEMBLY_LEVEL";   MATCH="ASSEMBLY_LEVEL_MATCH";   LABEL="assembly level" ;;
        GTDB_TAXON)       NAME="GTDB_TAXON";       MATCH="GTDB_TAXON_MATCH";       LABEL="GTDB taxon"; GTDB_FILTERS+=("${IDX}") ;;
        GTDB_TAXON_LIST)  NAME="GTDB_TAXON_LIST";  MATCH="GTDB_TAXON_LIST_MATCH";  LABEL="GTDB taxon list"; GTDB_FILTERS+=("${IDX}") ;;
        GENOME_TYPE)
            ARG1="${VALUES}"
            NAME="GENOME_TYPE-$(printf '%s' "${VALUES^^}" | tr '_' '-')"; LABEL="genome type" ;;
        GC)
            ARG1="${VALUES%%:*}"; ARG2="${VALUES#*:}"
            NAME="GC-${VALUES}"; LABEL="GC (%)" ;;
        GENOME_SIZE)
            ARG1="${VALUES%%:*}"; ARG2="${VALUES#*:}"
            NAME="GENOME_SIZE-${VALUES}"; LABEL="genome size (Mb)" ;;
        BACDIVE_RANGE)
            ARG1="${VALUES%%=*}"; ARG2="${VALUES#*=}"
            NAME="$(bacdive_trait_name "${ARG1}")-${ARG2}"; LABEL="BacDive ${ARG1}"
            BD_FILTERS+=("${IDX}") ;;
        BACDIVE_CLASS)
            ARG1="${VALUES%%=*}"; ARG2="${VALUES#*=}"
            NAME="$(bacdive_trait_name "${ARG1}")"; MATCH="${NAME}_MATCH"; LABEL="BacDive ${ARG1}"
            BD_FILTERS+=("${IDX}") ;;
    esac
    NAME="SELECTED_BY_${NAME}"
    if [[ -n "${USED_NAME[${NAME}]:-}" ]]; then
        N=2
        while [[ -n "${USED_NAME[${NAME}_${N}]:-}" ]]; do N=$((N + 1)); done
        NAME="${NAME}_${N}"
        [[ -n "${MATCH}" ]] && MATCH="${MATCH}_${N}"
    fi
    USED_NAME["${NAME}"]=1
    case "${KEY}" in
        GENOME_TYPE|GC|GENOME_SIZE|BACDIVE_RANGE|BACDIVE_CLASS) LABEL="${LABEL} ${VALUES#*=}" ;;
        *)
            SHOWN="$(printf '%s\n' "${VALUES}" | awk 'NR <= 5 { printf "%s%s", (NR > 1 ? "," : ""), $0 } END { if (NR > 5) printf ",... (%d values)", NR }')"
            LABEL="${LABEL} (${SHOWN})"
            ;;
    esac
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${IDX}" "${KEY}" "${ARG1}" "${ARG2}" "${NAME}" "${MATCH}" "${LABEL}" >> "${FILTERS_SPEC}"
    case "${KEY}" in
        ACCESSION|TAXID|ISOLATION_SOURCE|ASSEMBLY_LEVEL|GTDB_TAXON|GTDB_TAXON_LIST)
            printf '%s\n' "${VALUES}" | awk -v i="${IDX}" -v OFS='\t' 'NF { print i, $0 }' >> "${FILTER_VALUES}" ;;
    esac
done

log "message" "Searching the reference database (NCBI ${Q_ASSEMBLY_SOURCE} tables)..."
log "message" "Selection expression: ${EXPRESSION}"

############ BACDIVE FILTERS ################
#   One row per species (the BacDive strains of the same current species merged). Range filters: the value of the species
#   (mean of its strains) is inside the range. Class filters: at least one of the requested classes was recorded for
#   the species (its column <trait>_<class> is greater than 0). Species with no value for a filtered trait do not pass.
#   Output: one line per species: <taxid> and, per BacDive filter, "1" (range) or the classes found ("" = no).

BD_LINKS_FILE=""
if [[ "${#BD_FILTERS[@]}" -gt 0 ]]; then
    if [[ ! -f "${BACDIVE_TSV}" ]]; then
        die "BacDive filters require the BacDive species table, which was not found: ${BACDIVE_TSV}. Update the reference databases with: main-prokfinder.sh setup"
    fi
    BD_SPEC="${WORK_DIR}/bacdive.spec"   # <filter index> <kind> <column index(es)> <arg1> <arg2> <label>
    : > "${BD_SPEC}"
    for IDX in "${BD_FILTERS[@]}"; do
        # (fields separated by \x1f: unlike TAB, it keeps the empty fields when read)
        IFS=$'\x1f' read -r KEY ARG1 ARG2 LABEL < <(awk -F'\t' -v OFS='\x1f' -v i="${IDX}" '$1 == i { print $2, $3, $4, $7 }' "${FILTERS_SPEC}")
        if [[ "${KEY}" == "BACDIVE_RANGE" ]]; then
            COL="$(get_column_index "${BACDIVE_TSV}" "${ARG1}")"
            [[ -n "${COL}" ]] || die "Column '${ARG1}' not found in ${BACDIVE_TSV}."
            printf '%s\trange\t%s\t%s\t%s\t%s\n' "${IDX}" "${COL}" "${ARG2%%:*}" "${ARG2#*:}" "${LABEL}" >> "${BD_SPEC}"
        else
            # one column per class: <trait>_<class>
            COLS=""
            for CLASS in ${ARG2//,/ }; do
                COL="$(get_column_index "${BACDIVE_TSV}" "${ARG1}_${CLASS}")"
                [[ -n "${COL}" ]] || die "Column '${ARG1}_${CLASS}' not found in ${BACDIVE_TSV}."
                COLS="${COLS:+${COLS},}${COL}"
            done
            printf '%s\tclass\t%s\t%s\t\t%s\n' "${IDX}" "${COLS}" "${ARG2}" "${LABEL}" >> "${BD_SPEC}"
        fi
    done

    log "message" "BacDive filters (one row per species, strains merged):"
    BD_LINKS_FILE="${WORK_DIR}/bacdive_links.tsv"
    awk -F'\t' -v OFS='\t' -v c_taxid="$(require_column "${BACDIVE_TSV}" ncbi_tax_id)" -v spec="${BD_SPEC}" \
        -v stats="${WORK_DIR}/bacdive.stats" "${AWK_LIB}"'
    BEGIN {
        while ((getline line < spec) > 0) {
            split(line, f, "\t"); n++
            kind[n] = f[2]; label[n] = f[6]
            if (kind[n] == "class") {
                ncl[n] = split(f[3], cc, ","); split(f[4], cn, ",")
                for (k = 1; k <= ncl[n]; k++) { ccol[n, k] = cc[k] + 0; cname[n, k] = cn[k] }
            } else { col[n] = f[3] + 0; a[n] = f[4]; b[n] = f[5] }
        }
        close(spec)
    }
    NR == 1 { next }
    {
        if (is_empty($c_taxid)) next
        out = $c_taxid
        for (i = 1; i <= n; i++) {
            if (kind[i] == "range") v = (any_in_range($(col[i]), a[i], b[i]) ? "1" : "")
            else {
                v = ""
                for (k = 1; k <= ncl[i]; k++) if (is_number($(ccol[i, k])) && $(ccol[i, k]) + 0 > 0) v = v (v == "" ? "" : ";") cname[i, k]
            }
            if (v != "") n_match[i]++
            out = out OFS v
        }
        print out
    }
    END {
        # per filter, e.g. "BacDive temperature_opt 45:80: 231 species match"
        for (i = 1; i <= n; i++) printf "  %s -> %d species match\n", label[i], n_match[i] + 0 > stats
    }' "${BACDIVE_TSV}" > "${BD_LINKS_FILE}"
    while IFS= read -r LINE; do
        log "message" "${LINE}"
    done < "${WORK_DIR}/bacdive.stats"
fi

############ GTDB FILTERS ################
#   <key> <TAB> <filter index> <TAB> taxa of the filter found in the GTDB lineage of the genome (a name with the rank
#   prefix, e.g. g__Thermus, matches only that rank)

GTDB_KEYS_FILE=""
if [[ "${#GTDB_FILTERS[@]}" -gt 0 ]]; then
    GTDB_DIR="${REF_DIR}/GTDB"
    GTDB_TAX_TABLES=()
    for DOMAIN in "${PF_DOMAINS[@]}"; do
        TABLE="$(pf_gtdb_taxonomy_table "${GTDB_DIR}" "${DOMAIN}")"
        [[ -f "${TABLE}" ]] || die "GTDB taxonomy table not found: ${TABLE}. Install the reference databases with: main-prokfinder.sh setup"
        GTDB_TAX_TABLES+=("${TABLE}")
    done
    GTDB_KEYS_FILE="${WORK_DIR}/gtdb_keys.tsv"
    awk -F'\t' -v OFS='\t' -v values="${FILTER_VALUES}" -v spec="${FILTERS_SPEC}" "${AWK_LIB}"'
        BEGIN {
            letter["GTDB_DOMAIN"] = "d"; letter["GTDB_PHYLUM"] = "p"; letter["GTDB_CLASS"] = "c"; letter["GTDB_ORDER"] = "o"
            letter["GTDB_FAMILY"] = "f"; letter["GTDB_GENUS"] = "g"; letter["GTDB_SPECIES"] = "s"
            while ((getline line < spec) > 0) { split(line, f, "\t"); if (f[2] ~ /^GTDB_TAXON/) gtdb[f[1]] = 1 }
            close(spec)
            # want[name] = SUBSEP <filter>=<rank letter or "">=<value as written> ...
            while ((getline line < values) > 0) {
                split(line, f, "\t")
                if (!(f[1] in gtdb)) continue
                v = tolower(f[2]); r = ""
                if (v ~ /^[dpcofgs]__/) { r = substr(v, 1, 1); v = substr(v, 4) }
                want[v] = want[v] SUBSEP f[1] "=" r "=" f[2]
            }
            close(values)
        }
        FNR == 1 { delete rank_col; for (i = 1; i <= NF; i++) if ($i in letter) rank_col[i] = letter[$i]; next }
        {
            delete found
            for (i in rank_col) {
                v = tolower($i)
                if (!(v in want)) continue
                m = split(substr(want[v], 2), items, SUBSEP)
                for (k = 1; k <= m; k++) {
                    split(items[k], p, "=")
                    if (p[2] != "" && p[2] != rank_col[i]) continue
                    found[p[1]] = (p[1] in found ? found[p[1]] ";" : "") substr(items[k], length(p[1]) + length(p[2]) + 3)
                }
            }
            for (fi in found) print acc_base($1), fi, found[fi]
        }
    ' "${GTDB_TAX_TABLES[@]}" > "${GTDB_KEYS_FILE}"
fi

############ TAXON NAMES ################
#   <filter index> <TAB> <taxid> <TAB> <name>

TAXON_NAME_FILE=""
if [[ "${HAS_TAXON_NAME}" -eq 1 ]]; then
    TAXON_NAME_FILE="${WORK_DIR}/taxon_name_filters.tsv"
    : > "${WORK_DIR}/taxon_name_values.tsv"
    for (( I = 0; I < ${#F_IDS[@]}; I++ )); do
        [[ "${F_KEY[${F_IDS[$I]}]}" == TAXON_NAME* ]] || continue
        printf '%s' "${F_VALUES[${F_IDS[$I]}]}" | awk -v i="$((I + 1))" -v OFS='\t' 'NF { print i, $0 }' >> "${WORK_DIR}/taxon_name_values.tsv"
    done
    awk -F'\t' -v OFS='\t' -v names="${WORK_DIR}/taxon_names.tsv" '
        BEGIN {
            while ((getline line < names) > 0) { split(line, f, "\t"); ids[tolower(f[2])] = ids[tolower(f[2])] " " f[1] }
            close(names)
        }
        { m = split(ids[tolower($2)], t, " "); for (k = 1; k <= m; k++) print $1, t[k], $2 }
    ' "${WORK_DIR}/taxon_name_values.tsv" > "${TAXON_NAME_FILE}"
fi

############ NCBI ASSEMBLIES ################
#   Every assembly is checked against every filter; the expression (in postfix notation) decides the selection.

C_ACC="$(require_column "${NCBI_HEADER_FILE}" ASSEMBLY_ACCESSION)"
C_ISO="$(require_column "${NCBI_HEADER_FILE}" ASSEMBLY_BIOSAMPLE_ISOLATION_SOURCE)"
C_LEVEL="$(require_column "${NCBI_HEADER_FILE}" ASSEMBLY_LEVEL)"
C_SIZE="$(require_column "${NCBI_HEADER_FILE}" ASSEMBLY_STATS_TOTAL_SEQUENCE_LENGTH)"
C_GTYPE="$(require_column "${NCBI_HEADER_FILE}" GENOME_TYPE)"
C_GC="$(require_column "${NCBI_HEADER_FILE}" ASSEMBLY_STATS_GC_PERCENT)"

# The NCBI TaxID of each assembly is the normalized one (<source>-taxid-status.tsv: current TaxID, species). A TaxID
# filter matches an assembly when the requested TaxID is its TaxID or one of its ancestors in the NCBI taxonomy
# (nodes.dmp), whatever the rank. Assemblies without a current TaxID (UNRESOLVED) are found by no TaxID filter.

SELECTED_TMP="${WORK_DIR}/selected.tsv"
ACC_NOT_FOUND="${WORK_DIR}/accessions-not-found.txt"
TAXID_BELOW_SPECIES="${WORK_DIR}/taxids-below-species.tsv"
: > "${ACC_NOT_FOUND}"
: > "${TAXID_BELOW_SPECIES}"
# species of the BacDive table (first column, current TaxIDs), for NCBI_SPECIES_IN_BACDIVE
BD_SPECIES_FILE=""; BD_TAXID_COL=0
if [[ -f "${BACDIVE_TSV}" ]]; then
    BD_SPECIES_FILE="${BACDIVE_TSV}"
    BD_TAXID_COL="$(require_column "${BACDIVE_TSV}" ncbi_tax_id)"
fi

awk -F'\t' -v OFS='\t' -v missing="${ACC_NOT_FOUND}" -v below_file="${TAXID_BELOW_SPECIES}" \
    -v c_acc="${C_ACC}" -v c_iso="${C_ISO}" -v c_level="${C_LEVEL}" -v c_size="${C_SIZE}" \
    -v c_gtype="${C_GTYPE}" -v c_gc="${C_GC}" -v status_list="${NCBI_STATUS_LIST}" -v nodes_file="${NCBI_NODES}" \
    -v spec="${FILTERS_SPEC}" -v values="${FILTER_VALUES}" -v bd_file="${BD_LINKS_FILE}" \
    -v bd_species_file="${BD_SPECIES_FILE}" -v c_bd_taxid="${BD_TAXID_COL}" \
    -v gtdb_file="${GTDB_KEYS_FILE}" -v tname_file="${TAXON_NAME_FILE}" \
    -v rpn="${RPN[*]}" -v stats="${WORK_DIR}/selection.stats" "${AWK_LIB}"'
function norm(s) { s = tolower(s); gsub(/[^a-z0-9]+/, " ", s); sub(/ +$/, "", s); return " " s }
function add_unique(list, v) { return (index(";" list ";", ";" v ";") > 0 ? list : list (list == "" ? "" : ";") v) }
# species the TaxID belongs to (the TaxID itself when it is a species; "" when it is above species rank)
function species_of(t,   n) {
    for (n = 0; n < 64 && (t in parent); n++) {
        if (t in is_species) return t
        if (parent[t] == t) return ""
        t = parent[t]
    }
    return ""
}
# values of filter i for the TaxID t and every ancestor of it (the same TaxID is looked up once per filter)
function lineage_match(i, t,   cur, n, m) {
    if ((i, t) in memo) return memo[i, t]
    m = ""; cur = t
    for (n = 0; n < 64 && cur != ""; n++) {
        if ((i, cur) in set) m = add_unique(m, set[i, cur])
        if (!(cur in parent) || parent[cur] == cur) break
        cur = parent[cur]
    }
    memo[i, t] = m
    return m
}
BEGIN {
    while ((getline line < spec) > 0) {
        split(line, f, "\t"); n++
        key[n] = f[2]; a1[n] = f[3]; a2[n] = f[4]; sel[n] = f[5]; mname[n] = f[6]; label[n] = f[7]
    }
    close(spec)
    # Values of the filters with a list (nv[i] values; for the text filters, the text to search and the original)
    while ((getline line < values) > 0) {
        split(line, f, "\t"); i = f[1]; v = f[2]
        if (key[i] == "ACCESSION")             { set[i, v] = 1; acc_asked[v] = 1 }
        else if (key[i] == "ISOLATION_SOURCE") { nv[i]++; txt[i, nv[i]] = tolower(v); orig[i, nv[i]] = v }
        else if (key[i] == "TAXID")            set[i, v] = v
        else if (key[i] == "ASSEMBLY_LEVEL")   set[i, tolower(v)] = v
    }
    close(values)
    if (tname_file != "") { while ((getline line < tname_file) > 0) { split(line, f, "\t"); set[f[1], f[2]] = (((f[1], f[2]) in set) ? set[f[1], f[2]] ";" : "") f[3] } close(tname_file) }
    if (gtdb_file != "")  { while ((getline line < gtdb_file) > 0)  { split(line, f, "\t"); gtdb[f[2], f[1]] = f[3] } close(gtdb_file) }
    # BacDive: column of each BacDive filter in the links file (2 = first filter; 1 = the TaxID of the species)
    nb = 0
    for (i = 1; i <= n; i++) if (key[i] ~ /^BACDIVE_/) bd_col[i] = 1 + (++nb)
    if (bd_file != "") {
        while ((getline line < bd_file) > 0) { split(line, f, "\t"); bd_row[f[1]] = line }
        close(bd_file)
    }
    nr = split(rpn, op, " ")
    # taxonomy: nodes.dmp "<taxid> | <parent> | <rank> | ..." (TaxID filters, species of the TaxIDs asked, ancestors of
    # the species of BacDive)
    while ((getline line < nodes_file) > 0) { split(line, f, /\t\|\t?/); parent[f[1]] = f[2]; if (f[3] == "species") is_species[f[1]] = 1 }
    close(nodes_file)
    # species of BacDive and their ancestors (NCBI_SPECIES_IN_BACDIVE)
    if (bd_species_file != "") {
        nl = 0
        while ((getline line < bd_species_file) > 0) {
            if (++nl == 1) continue
            split(line, f, "\t")
            t = f[c_bd_taxid]
            if (is_empty(t)) continue
            bd_species[t] = 1
            cur = t
            for (q = 0; q < 64 && (cur in parent) && parent[cur] != cur; q++) { cur = parent[cur]; bd_ancestor[cur] = 1 }
        }
        close(bd_species_file)
    }
    # a TaxID asked (-t, -N) below species rank is replaced by its species
    for (ik in set) {
        split(ik, pk, SUBSEP)
        if (key[pk[1]] != "TAXID" && key[pk[1]] != "TAXON_NAME" && key[pk[1]] != "TAXON_NAME_LIST") continue
        sp_of = species_of(pk[2])
        if (sp_of != "" && sp_of != pk[2]) { moved[pk[1], sp_of] = (((pk[1], sp_of) in moved) ? moved[pk[1], sp_of] ";" : "") set[ik]; below[pk[2]] = sp_of }
    }
    for (ik in moved) { split(ik, pk, SUBSEP); set[ik] = (ik in set ? add_unique(set[ik], moved[ik]) : moved[ik]) }
    for (v in below) print v, below[v] > below_file
    close(below_file)
    # normalized TaxID of each assembly (<source>-taxid-status.tsv: ASSEMBLY_ACCESSION, TAXID, TAXID_STATUS,
    # UPDATED_TAXID, RANK, UPDATED_RANK, UPDATED_ORGANISM_NAME, TAXDUMP_DATE)
    ns = split(status_list, status_file, ",")
    for (k = 1; k <= ns; k++) {
        nl = 0
        while ((getline line < status_file[k]) > 0) {
            split(line, f, "\t")
            if (++nl == 1) {
                if (f[6] != "UPDATED_RANK" || f[7] != "UPDATED_ORGANISM_NAME") {
                    print "ERROR: " status_file[k] " is not in the current format (no UPDATED_RANK/UPDATED_ORGANISM_NAME): run main-prokfinder.sh setup" > "/dev/stderr"
                    exit 1
                }
                continue
            }
            tstatus[f[1]] = f[3]; tupdated[f[1]] = (is_empty(f[4]) ? "" : f[4]); trank[f[1]] = (is_empty(f[6]) ? "" : f[6])
            tname[f[1]] = (is_empty(f[7]) ? "" : f[7])
        }
        close(status_file[k])
    }
}
FNR == 1 {
    if (NR == 1) {
        # each SELECTED_BY column is followed by its column of matched values (filters with several values)
        out = $0 OFS "NCBI_TAXID_STATUS" OFS "NCBI_UPDATED_TAXID" OFS "NCBI_UPDATED_RANK" OFS "NCBI_UPDATED_ORGANISM_NAME" OFS "NCBI_SPECIES_IN_BACDIVE"
        for (i = 1; i <= n; i++) out = out OFS sel[i] (mname[i] != "" ? OFS mname[i] : "")
        print out
    }
    next
}
{
    n_in++
    key_gtdb = acc_base($c_acc)
    # current TaxID, rank and name of the assembly (empty when the TaxID could not be resolved)
    upd_taxid = ($c_acc in tupdated ? tupdated[$c_acc] : "")
    upd_rank = ($c_acc in trank ? trank[$c_acc] : "")
    # BacDive row of the assembly: the row of its species (an assembly above species rank is not linked)
    bd = ""
    if (nb > 0 && upd_rank == "species" && (upd_taxid in bd_row)) { bd = bd_row[upd_taxid]; split(bd, bdf, "\t") }
    # the species of the assembly (or, above species, a species below it) has a row in BacDive
    in_bacdive = (upd_taxid != "" && ((upd_taxid in bd_species) || (upd_taxid in bd_ancestor)) ? "TRUE" : "FALSE")

    for (i = 1; i <= n; i++) {
        m = ""
        k = key[i]
        if (k == "ACCESSION") {
            # the whole accession: GCA_ only in the GenBank table, GCF_ only in the RefSeq table
            p = ((i, $c_acc) in set)
            if (p) acc_found[$c_acc] = 1
        } else if (k == "TAXID" || k == "TAXON_NAME" || k == "TAXON_NAME_LIST") {
            if (upd_taxid != "") m = lineage_match(i, upd_taxid)
            p = (m != "")
        } else if (k == "ASSEMBLY_LEVEL") {
            if ((i, tolower($c_level)) in set) m = set[i, tolower($c_level)]
            p = (m != "")
        } else if (k == "ISOLATION_SOURCE") {
            # case-insensitive regular expression
            if (!is_empty($c_iso)) {
                text = tolower($c_iso)
                for (j = 1; j <= nv[i]; j++) if (text ~ txt[i, j]) m = add_unique(m, orig[i, j])
            }
            p = (m != "")
        } else if (k == "GTDB_TAXON" || k == "GTDB_TAXON_LIST") {
            m = (((i, key_gtdb) in gtdb) ? gtdb[i, key_gtdb] : "")
            p = (m != "")
        } else if (k == "GENOME_TYPE") {
            p = (tolower($c_gtype) == a1[i])
        } else if (k == "GC") {
            p = any_in_range($c_gc, a1[i], a2[i])
        } else if (k == "GENOME_SIZE") {
            # total sequence length in bases; the filter is in Mb
            p = is_number($c_size) && ((a1[i] == "" || $c_size / 1000000 >= a1[i] + 0) && (a2[i] == "" || $c_size / 1000000 <= a2[i] + 0))
        } else {
            # BacDive filters
            v = (bd == "" ? "" : bdf[bd_col[i]])
            p = (v != "")
            if (k == "BACDIVE_CLASS") m = v
        }
        pass[i] = p; mval[i] = m
        if (p) n_true[i]++
    }

    # Evaluation of the expression (postfix notation)
    sp = 0
    for (j = 1; j <= nr; j++) {
        if (op[j] == "AND")     { sp--; st[sp] = st[sp] && st[sp + 1] }
        else if (op[j] == "OR") { sp--; st[sp] = st[sp] || st[sp + 1] }
        else                    { st[++sp] = pass[op[j]] }
    }
    if (!st[1]) next
    n_sel++

    out = $0 OFS ($c_acc in tstatus ? tstatus[$c_acc] : "NULL") OFS (upd_taxid == "" ? "NULL" : upd_taxid) OFS (upd_rank == "" ? "NULL" : upd_rank) \
        OFS (($c_acc in tname) && tname[$c_acc] != "" ? tname[$c_acc] : "NULL") OFS in_bacdive
    for (i = 1; i <= n; i++) out = out OFS (pass[i] ? "TRUE" : "FALSE") (mname[i] != "" ? OFS (mval[i] == "" ? "NULL" : mval[i]) : "")
    print out
}
END {
    printf "NCBI genome assemblies searched\t%d\n", n_in > stats
    for (i = 1; i <= n; i++) printf "  ... matching %s [%s]\t%d\n", label[i], sel[i], n_true[i] > stats
    printf "Selected by the expression\t%d\n", n_sel > stats
    for (a in acc_asked) if (!(a in acc_found)) print a > missing
}' "${NCBI_TABLES[@]}" > "${SELECTED_TMP}"

while IFS=$'\t' read -r LABEL VALUE; do
    log "message" "${LABEL}: ${VALUE}"
done < "${WORK_DIR}/selection.stats"

# TaxIDs asked below the species rank (strain, subspecies...): the mapping stops at the species
while IFS=$'\t' read -r ASKED SPECIES_ASKED; do
    log "warning" "NCBI TaxID ${ASKED} is below the species rank: the search uses its species, TaxID ${SPECIES_ASKED}."
done < <(sort -n "${TAXID_BELOW_SPECIES}")

# Accessions of the accession filters that are not in the searched table (e.g., GCF_ with the GenBank table)
if [[ -s "${ACC_NOT_FOUND}" ]]; then
    sort -o "${ACC_NOT_FOUND}" "${ACC_NOT_FOUND}"
    N_NOT_FOUND="$(count_lines "${ACC_NOT_FOUND}")"
    log "warning" "${N_NOT_FOUND} accession(s) not found in the NCBI ${Q_ASSEMBLY_SOURCE} table, so not selected: $(awk 'NR <= 10' "${ACC_NOT_FOUND}" | paste -sd ' ')$( (( N_NOT_FOUND > 10 )) && echo ' ...'). GCA_ accessions are in the genbank table and GCF_ in the refseq table (-s/--assembly-source)."
fi
TOTAL_SELECTED="$(count_records "${SELECTED_TMP}")"

############ BACDIVE ANNOTATION ################
#   The BacDive traits of each selected assembly are added as BACDIVE_* columns, from the species table (strains of the
#   same species merged). An assembly uses the row of its species (NCBI_UPDATED_TAXID) when its NCBI_UPDATED_RANK is
#   species; an assembly above species rank, or whose species is not in BacDive, has NULL. The traits divided in classes
#   have one column per class (BACDIVE_<TRAIT>_<CLASS>: the share of the strains that recorded it).

if [[ -f "${BACDIVE_TSV}" && "${TOTAL_SELECTED}" -gt 0 ]]; then
    log "message" "Adding the BacDive traits of the selected genomes..."
    BD_SPEC=""
    for TRAIT in bacdive_strains ${BACDIVE_ANNOTATION_TRAITS[@]+"${BACDIVE_ANNOTATION_TRAITS[@]}"}; do
        INDEX="$(get_column_index "${BACDIVE_TSV}" "${TRAIT}")"
        if [[ -n "${INDEX}" ]]; then
            BD_SPEC="${BD_SPEC:+${BD_SPEC},}${INDEX}=${TRAIT}"
        fi
    done

    # (the NCBI TaxID columns of the selected table: NCBI_UPDATED_TAXID and NCBI_UPDATED_RANK, written above)
    awk -F'\t' -v OFS='\t' -v bd_file="${BACDIVE_TSV}" \
        -v bd_taxid_col="$(require_column "${BACDIVE_TSV}" ncbi_tax_id)" \
        -v spec="${BD_SPEC}" -v c_acc="${C_ACC}" -v c_updated_taxid="$(require_column "${SELECTED_TMP}" NCBI_UPDATED_TAXID)" \
        -v c_updated_rank="$(require_column "${SELECTED_TMP}" NCBI_UPDATED_RANK)" "${AWK_LIB}"'
    BEGIN {
        ns = split(spec, sp, ",")
        for (k = 1; k <= ns; k++) { split(sp[k], p, "="); col[k] = p[1] + 0; name[k] = (p[2] == "bacdive_strains" ? "BACDIVE_STRAINS" : "BACDIVE_" toupper(p[2])) }
        while ((getline line < bd_file) > 0) {
            if (++rows == 1) continue
            split(line, f, "\t")
            if (is_empty(f[bd_taxid_col])) continue
            v = ""
            for (k = 1; k <= ns; k++) v = v OFS (f[col[k]] == "" ? "NULL" : f[col[k]])
            species_row[f[bd_taxid_col]] = v
        }
        close(bd_file)
        out = "ASSEMBLY_ACCESSION" OFS "BACDIVE_TAXID"
        for (k = 1; k <= ns; k++) out = out OFS name[k]
        print out
        empty = ""
        for (k = 1; k <= ns; k++) empty = empty OFS "NULL"
    }
    NR == 1 { next }
    {
        t = (($c_updated_rank == "species") && ($c_updated_taxid in species_row)) ? $c_updated_taxid : ""
        if (t == "") print $c_acc, "NULL" empty
        else print $c_acc, t species_row[t]
    }' "${SELECTED_TMP}" > "${WORK_DIR}/bacdive_annotation.tsv"

    add_metadata_columns "${SELECTED_TMP}" "${WORK_DIR}/bacdive_annotation.tsv"
    log "message" "  Selected genomes linked to BacDive (the species has a row): $(awk -F'\t' 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == "BACDIVE_TAXID") c = i; next } $c != "NULL" { t++ } END { printf "%d", t }' "${SELECTED_TMP}")"
fi

# Nothing else is read from the taxdump or the status tables
if [[ "${TAXDUMP_LOCKED}" -eq 1 ]]; then
    flock -u 9
    exec 9<&-
fi

mkdir -p "$(dirname "${OUTPUT_TSV}")"
mv "${SELECTED_TMP}" "${OUTPUT_TSV}"
log "message" "Selected genome metadata (one row per assembly, with the SELECTED_BY_* columns) saved to: ${OUTPUT_TSV}"
