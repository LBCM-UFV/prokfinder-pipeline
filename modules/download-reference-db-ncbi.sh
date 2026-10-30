#!/usr/bin/env bash
#
# download-reference-db-ncbi.sh - Prokfinder module 0.1: NCBI reference database
#
# Downloads the dehydrated genome packages (assembly reports + fetch.txt) of Bacteria and Archaea from NCBI
# and turns the assembly reports into curated TSV tables:
#   1. datasets download (dehydrated): only fetch.txt and the assembly reports, not the FASTA files
#   2. dataformat: assembly reports (JSONL) -> TSV with the fields in FIELDS
#   3. rows of the same accession (fields with several values produce several rows) are merged into one row;
#      the different values of a cell are joined with ";"
#   4. header: spaces -> "_" (upper case); empty/invalid cells ("missing", "not ...", NA, N/A, ND, NaN) -> NULL,
#      every converted value listed in NULL-VALUES-NCBI.tsv (see PF_AWK_NULL in lib/common.sh)
#   5. the table is split into GenBank (GCA_ accessions) and RefSeq (GCF_ accessions); each table gets the accession
#      of the paired assembly of the other database (NULL when there is none, or when NCBI says that the GenBank and
#      the RefSeq assemblies are different: then there is no correspondence between them)
#   6. OPTIONAL (--complete-table): complete table with EVERY field of the assembly reports (dataformat default
#      fields), one row per accession; fields with several values are joined with ";" (paired fields, such as the
#      BioSample attribute names and values, are kept aligned: the n-th name goes with the n-th value). It is slow
#      (many hours for Bacteria) and is not used by the genome search
#
# The assembly reports are downloaded only once: a domain whose assembly reports are already on disk is not
# downloaded again, and only the missing tables are written from them. Tables written by an older Prokfinder (older
# format in the checkpoint) are rebuilt from the assembly reports already downloaded.
#
# Requests for very large taxa (e.g., Bacteria, >3M records) fail when made in a single call (stream error /
# INTERNAL_ERROR). To avoid this, each domain is split into chunks by release date (one per year), downloaded
# separately and merged afterwards. Chunks already downloaded are reused if the script is interrupted.
#
# The NCBI taxonomy (taxdump) and the normalization of the TaxIDs are not done here: see normalize-ncbi-taxids.sh.
#
# Usage: download-reference-db-ncbi.sh -o <ncbi_dir> [--assembly-source all|genbank|refseq]
#                                      [--complete-table] [--force]
#
# Output (per domain, <DOMAIN> = BACTERIA or ARCHAEA):
#   <ncbi_dir>/<DOMAIN>-NCBI-GENOMES/fetch.txt                    (locations of the genome FASTA files)
#   <ncbi_dir>/<DOMAIN>-NCBI-METADATA/assembly_data_report.jsonl  (raw assembly reports)
#   <ncbi_dir>/<DOMAIN>-NCBI-METADATA/genbank-metadata.tsv        (curated table, GCA_ accessions)
#   <ncbi_dir>/<DOMAIN>-NCBI-METADATA/refseq-metadata.tsv         (curated table, GCF_ accessions)
#   <ncbi_dir>/<DOMAIN>-NCBI-METADATA/complete-metadata.tsv       (OPTIONAL: every field, GCA_ and GCF_ accessions)
#   <ncbi_dir>/COMPLETED-DOWNLOAD.txt                             (checkpoint: written only at the end)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

############ READING PARAMETERS ################

usage() {
    cat << EOF
Usage: $(basename "$0") -o <ncbi_dir> [options]

  -o <ncbi_dir>              Directory where the NCBI reference data will be saved (required)
  --assembly-source <src>    all, genbank or refseq (default: all; the tables are split into GenBank and RefSeq anyway)
  --complete-table           Also write complete-metadata.tsv: every field of the assembly reports converted to TSV
                             (slow: many hours for Bacteria; not used by the genome search)
  --force                    Remove the previous download of this module and start again
  -h                         Show this help message

EOF
    exit "${1:-1}"
}

OUTPUT_DIR=""
ASSEMBLY_SOURCE="all"
COMPLETE_TABLE=0
FORCE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) OUTPUT_DIR="${2%/}"; shift 2 ;;
        --assembly-source) ASSEMBLY_SOURCE="$(echo "$2" | tr '[:upper:]' '[:lower:]')"; shift 2 ;;
        --complete-table) COMPLETE_TABLE=1; shift ;;
        --force) FORCE=1; shift ;;
        -h|--help) usage 0 ;;
        *) log "error" "Invalid option: $1"; usage ;;
    esac
done

if [[ -z "${OUTPUT_DIR}" ]]; then
    log "error" "Output directory (-o) is required."
    usage
fi

case "${ASSEMBLY_SOURCE}" in
    all)     DATASETS_SOURCE="all" ;;
    genbank) DATASETS_SOURCE="GenBank" ;;
    refseq)  DATASETS_SOURCE="RefSeq" ;;
    *) die "Invalid --assembly-source '${ASSEMBLY_SOURCE}'. Must be all, genbank or refseq." ;;
esac

mkdir -p "${OUTPUT_DIR}"
setup_module_log "${OUTPUT_DIR}/download-reference-db-ncbi.log"
require_programs datasets dataformat unzip

############ SETTINGS ################

FIELDS="accession,organism-name,organism-tax-id,organism-infraspecific-strain,assminfo-level,assminfo-release-date,assminfo-biosample-accession,assminfo-biosample-isolation-source,assminfo-biosample-geo-loc-name,assminfo-biosample-lat-lon,assminfo-biosample-host,assminfo-biosample-collection-date,assmstats-total-sequence-len,assmstats-gc-percent,assmstats-number-of-contigs,assmstats-contig-n50,checkm-completeness,checkm-contamination,assminfo-notes,assminfo-paired-assm-accession,assminfo-paired-assm-refseq-genbank-are-different"
declare -A DOMAIN_TAXID=( ["BACTERIA"]="2" ["ARCHAEA"]="2157" )

# Chunks by release year: everything released up to 12/31 of FIRST_YEAR goes in a single chunk,
# then one chunk per year until the current year
FIRST_YEAR=2017
CURRENT_YEAR="$(date +%Y)"
MAX_ATTEMPTS=5      # attempts per chunk before giving up
RETRY_WAIT=10       # seconds between attempts

COMPLETED_MARKER="$(pf_completed_marker "${OUTPUT_DIR}")"

############ FUNCTIONS ################

# Returns 0 if the ZIP file exists and is intact
check_download_zip() {
    [[ -f "$1" ]] && unzip -qq -t "$1" > /dev/null 2>&1
}

# Downloads the dehydrated dataset of one release year, retrying on failures (connection drops, corrupted ZIP)
# Usage: download_year_chunk <taxid> <year> <zip_file>
# Return: 0 = downloaded / 1 = failed after all attempts / 2 = no genomes released in that year
download_year_chunk() {
    local TAXID="$1"
    local YEAR="$2"
    local ZIP_FILE="$3"
    local DATE_FILTER=()
    local ATTEMPT MSG RC

    # --released-before / --released-after: genomes released on or before / on or after the date (MM/DD/YYYY)
    if [[ "${YEAR}" -eq "${FIRST_YEAR}" ]]; then
        DATE_FILTER=(--released-before "12/31/${YEAR}")
    elif [[ "${YEAR}" -eq "${CURRENT_YEAR}" ]]; then
        DATE_FILTER=(--released-after "01/01/${YEAR}")
    else
        DATE_FILTER=(--released-after "01/01/${YEAR}" --released-before "12/31/${YEAR}")
    fi

    for (( ATTEMPT = 1; ATTEMPT <= MAX_ATTEMPTS; ATTEMPT++ )); do
        rm -f "${ZIP_FILE}"

        # The message is kept to check whether there are genomes for this request
        RC=0
        MSG="$(datasets download genome taxon "${TAXID}" \
            --assembly-source "${DATASETS_SOURCE}" \
            --exclude-atypical \
            "${DATE_FILTER[@]}" \
            --dehydrated \
            --filename "${ZIP_FILE}" \
            --no-progressbar 2>&1)" || RC=$?

        # No genomes for this period (not an error)
        if grep -q "no genome assemblies that match your query" <<< "${MSG}"; then
            rm -f "${ZIP_FILE}"
            return 2
        fi

        if [[ "${RC}" -eq 0 ]] && check_download_zip "${ZIP_FILE}"; then
            return 0
        fi

        log "warning" "[${YEAR}] Attempt ${ATTEMPT}/${MAX_ATTEMPTS} failed: ${MSG:-download failed or ZIP file is corrupted}"

        if (( ATTEMPT < MAX_ATTEMPTS )); then
            log "message" "[${YEAR}] Waiting ${RETRY_WAIT} seconds before retrying..."
            sleep "${RETRY_WAIT}"
        fi
    done

    rm -f "${ZIP_FILE}"
    return 1
}

# awk function used by the merges below: 1 if a value is empty or invalid (the same rule as format_tsv), so it is
# left out of a list of values (a cell whose values are all invalid becomes NULL)
AWK_INVALID_VALUE="${PF_AWK_NULL}"'
function invalid(v) { return pf_null_rule(v) != "" }
'

# Merges consecutive rows of the same accession (first column) into one row. In each column the distinct
# valid values of the rows are joined with ";" (dataformat writes one row per value of multi-valued fields).
# Usage: merge_rows_by_accession < input.tsv > output.tsv
merge_rows_by_accession() {
    awk -F'\t' -v OFS='\t' "${AWK_INVALID_VALUE}"'
    function flush(   i, out) {
        if (current == "") return
        out = val[1]
        for (i = 2; i <= ncol; i++) out = out OFS val[i]
        print out
    }
    NR == 1 { ncol = NF; print; next }
    {
        if ($1 != current) {
            flush()
            current = $1
            delete seen
            for (i = 1; i <= ncol; i++) { val[i] = ((i > 1 && invalid($i)) ? "" : $i); seen[i, $i] = 1 }
            next
        }
        for (i = 2; i <= ncol; i++) {
            if (invalid($i) || ((i, $i) in seen)) continue
            seen[i, $i] = 1
            val[i] = (val[i] == "" ? $i : val[i] ";" $i)
        }
    }
    END { flush() }'
}

# Fields of the complete table that dataformat writes as parallel lists: each row holds one item of the list in every
# field of the group (e.g., one BioSample attribute: its name and its value). One extended regular expression per
# line, matched against the column names written by dataformat.
PAIRED_FIELD_GROUPS='^Assembly BioSample Attribute (Name|Value)$
^Assembly BioSample Sample Identifiers
^Assembly BioProject Lineage '

# Same as merge_rows_by_accession, but the fields of each group of PAIRED_FIELD_GROUPS are merged together: an item
# (the values of the group in one row) is added only once, to every field of the group, so the lists stay aligned
# (an empty value inside a list is written as NULL, and a ";" inside a value becomes ","). dataformat repeats each
# item for every item of the other groups.
# Usage: merge_rows_by_accession_paired < input.tsv > output.tsv
merge_rows_by_accession_paired() {
    awk -F'\t' -v OFS='\t' -v groups="${PAIRED_FIELD_GROUPS//$'\n'/\\n}" "${AWK_INVALID_VALUE}"'
    function item(k,   j, s) {
        s = ""
        for (j = 1; j <= gsize[k]; j++) s = s SUBSEP $(gcol[k, j])
        return s
    }
    function empty_item(k,   j) {
        for (j = 1; j <= gsize[k]; j++) if ($(gcol[k, j]) != "") return 0
        return 1
    }
    function add_item(k,   j, c, v) {
        for (j = 1; j <= gsize[k]; j++) {
            c = gcol[k, j]
            v = (invalid($c) ? "NULL" : $c)
            gsub(/;/, ",", v)
            val[c] = (gcount[k] == 0 ? v : val[c] ";" v)
        }
        gcount[k]++
    }
    function flush(   i, out) {
        if (current == "") return
        out = val[1]
        for (i = 2; i <= ncol; i++) out = out OFS val[i]
        print out
    }
    NR == 1 {
        ncol = NF
        ng = split(groups, gre, "\n")
        for (i = 1; i <= NF; i++) {
            grp[i] = 0
            for (k = 1; k <= ng; k++) if ($i ~ gre[k]) { grp[i] = k; gcol[k, ++gsize[k]] = i; break }
        }
        print
        next
    }
    {
        if ($1 != current) {
            flush()
            current = $1
            delete seen
            delete seen_item
            for (i = 1; i <= ncol; i++) if (grp[i] == 0) { val[i] = ((i > 1 && invalid($i)) ? "" : $i); seen[i, $i] = 1 } else val[i] = ""
            for (k = 1; k <= ng; k++) {
                gcount[k] = 0
                if (gsize[k] && !empty_item(k)) { seen_item[k, item(k)] = 1; add_item(k) }
            }
            next
        }
        for (i = 2; i <= ncol; i++) {
            if (grp[i] != 0 || invalid($i) || ((i, $i) in seen)) continue
            seen[i, $i] = 1
            val[i] = (val[i] == "" ? $i : val[i] ";" $i)
        }
        for (k = 1; k <= ng; k++) {
            if (!gsize[k] || empty_item(k)) continue
            it = item(k)
            if ((k, it) in seen_item) continue
            seen_item[k, it] = 1
            add_item(k)
        }
    }
    END { flush() }'
}

# Writes the complete table of a domain (every field of the assembly reports, one row per accession)
# Usage: build_complete_table <assembly_data_report.jsonl> <output_tsv>
build_complete_table() {
    local REPORT="$1"
    local OUTPUT="$2"
    dataformat tsv genome --force --inputfile "${REPORT}" \
        | merge_rows_by_accession_paired \
        | format_tsv 1 > "${OUTPUT}.tmp"
    mv "${OUTPUT}.tmp" "${OUTPUT}"
}

############ DOWNLOAD ################

if [[ "${FORCE}" -eq 1 ]]; then
    log "message" "Option --force: removing the previous NCBI reference data in ${OUTPUT_DIR}"
    rm -f "${COMPLETED_MARKER}"
    for DOMAIN in "${PF_DOMAINS[@]}"; do
        rm -rf "$(pf_ncbi_genomes_dir "${OUTPUT_DIR}" "${DOMAIN}")" "$(pf_ncbi_metadata_dir "${OUTPUT_DIR}" "${DOMAIN}")" \
               "${OUTPUT_DIR}/${DOMAIN}-YEARLY-CHUNKS"
    done
elif [[ -f "${COMPLETED_MARKER}" ]] && ! pf_refdb_format_ok "${OUTPUT_DIR}" "${PF_REFDB_FORMAT_NCBI}"; then
    # Tables of an older Prokfinder: they are rebuilt from the assembly reports already downloaded
    log "message" "The NCBI tables were written by an older version of Prokfinder: rebuilding them from the assembly reports already downloaded."
    for DOMAIN in "${PF_DOMAINS[@]}"; do
        rm -f "$(pf_ncbi_metadata_table "${OUTPUT_DIR}" "${DOMAIN}" genbank)" "$(pf_ncbi_metadata_table "${OUTPUT_DIR}" "${DOMAIN}" refseq)"
    done
fi

log "message" "Downloading NCBI reference data (assembly source: ${DATASETS_SOURCE}) into: ${OUTPUT_DIR}"
if [[ "${COMPLETE_TABLE}" -eq 1 ]]; then
    log "message" "Option --complete-table: the complete metadata table (every field) is also written (slow: many hours for Bacteria)."
fi
log "message" "datasets: $(datasets --version 2>&1 | head -n 1)"

for DOMAIN in "${PF_DOMAINS[@]}"; do
    TAXID="${DOMAIN_TAXID[$DOMAIN]}"

    GENOMES_DIR="$(pf_ncbi_genomes_dir "${OUTPUT_DIR}" "${DOMAIN}")"
    METADATA_DIR="$(pf_ncbi_metadata_dir "${OUTPUT_DIR}" "${DOMAIN}")"
    CHUNKS_DIR="${OUTPUT_DIR}/${DOMAIN}-YEARLY-CHUNKS"
    URL_FILE="$(pf_ncbi_fetch_file "${OUTPUT_DIR}" "${DOMAIN}")"
    REPORT_FILE="${METADATA_DIR}/assembly_data_report.jsonl"
    GENBANK_TSV="$(pf_ncbi_metadata_table "${OUTPUT_DIR}" "${DOMAIN}" genbank)"
    REFSEQ_TSV="$(pf_ncbi_metadata_table "${OUTPUT_DIR}" "${DOMAIN}" refseq)"
    COMPLETE_TSV="$(pf_ncbi_complete_table "${OUTPUT_DIR}" "${DOMAIN}")"

    # Left by an interrupted complete table
    rm -f "${COMPLETE_TSV}.tmp"

    # Domain already downloaded in a previous run (the curated tables are only written at the very end): only the
    # complete table is written, if it was asked for and is missing
    if [[ -f "${GENBANK_TSV}" && -f "${REFSEQ_TSV}" ]]; then
        if [[ "${COMPLETE_TABLE}" -eq 0 || -s "${COMPLETE_TSV}" ]]; then
            log "message" "Curated metadata for ${DOMAIN} already exist. Skipping..."
            continue
        fi
        if [[ -s "${REPORT_FILE}" ]]; then
            log "message" "[${DOMAIN}] Writing the complete metadata table (every field) from the assembly reports already downloaded..."
            build_complete_table "${REPORT_FILE}" "${COMPLETE_TSV}"
            log "message" "[${DOMAIN}] Complete metadata: $(count_records "${COMPLETE_TSV}") assemblies, $(head -n 1 "${COMPLETE_TSV}" | awk -F'\t' '{ print NF }') columns -> ${COMPLETE_TSV}"
            continue
        fi
        log "warning" "[${DOMAIN}] The assembly reports (${REPORT_FILE}) are missing: the domain is downloaded again."
    fi

    log "message" "Starting processing for domain: ${DOMAIN} (TaxID: ${TAXID})"
    mkdir -p "${GENOMES_DIR}" "${METADATA_DIR}"

    # The yearly chunks are removed only after the curated tables are written: assembly reports on disk without the
    # chunks folder are a finished download (e.g., tables of an older Prokfinder being rebuilt)
    if [[ -s "${REPORT_FILE}" && -s "${URL_FILE}" && ! -d "${CHUNKS_DIR}" ]]; then
        log "message" "[${DOMAIN}] Using the assembly reports already downloaded ($(wc -l < "${REPORT_FILE}") genome records): ${REPORT_FILE}"
    else
        mkdir -p "${CHUNKS_DIR}"

        # 1. Download one dehydrated chunk per release year
        for (( YEAR = FIRST_YEAR; YEAR <= CURRENT_YEAR; YEAR++ )); do
            ZIP_FILE="${CHUNKS_DIR}/${YEAR}.zip"

            # Chunks already downloaded in a previous (interrupted) run are reused
            if check_download_zip "${ZIP_FILE}"; then
                log "message" "[${DOMAIN}] ${YEAR}: chunk already downloaded. Skipping..."
                continue
            fi

            log "message" "[${DOMAIN}] ${YEAR}: downloading dehydrated dataset..."

            STATUS=0
            download_year_chunk "${TAXID}" "${YEAR}" "${ZIP_FILE}" || STATUS=$?

            case "${STATUS}" in
                0) log "message" "[${DOMAIN}] ${YEAR}: download complete ($(du -h "${ZIP_FILE}" | cut -f1))." ;;
                2) log "message" "[${DOMAIN}] ${YEAR}: no genomes found. Skipping..." ;;
                *) die "[${DOMAIN}] ${YEAR}: download failed after ${MAX_ATTEMPTS} attempts. Run the script again to resume." ;;
            esac
        done

        # 2. Merge the yearly fetch.txt and assembly_data_report.jsonl files (streamed directly from the ZIPs)
        log "message" "Merging yearly chunks of ${DOMAIN}..."
        : > "${URL_FILE}"
        : > "${REPORT_FILE}"

        for ZIP_FILE in "${CHUNKS_DIR}"/*.zip; do
            [[ -f "${ZIP_FILE}" ]] || continue
            unzip -p "${ZIP_FILE}" "ncbi_dataset/fetch.txt" >> "${URL_FILE}"
            unzip -p "${ZIP_FILE}" "ncbi_dataset/data/assembly_data_report.jsonl" >> "${REPORT_FILE}"
        done

        if [[ ! -s "${URL_FILE}" || ! -s "${REPORT_FILE}" ]]; then
            die "No genome records were downloaded for domain ${DOMAIN}."
        fi

        log "message" "[${DOMAIN}] Merged $(wc -l < "${REPORT_FILE}") genome records into: ${REPORT_FILE}"
    fi

    # 3-4. JSONL -> TSV, one row per accession, formatted header and NULL in empty/invalid cells.
    #      GENOME_TYPE is derived from the assembly notes (MAGs are "derived from metagenome").
    log "message" "[${DOMAIN}] Converting the assembly reports into a curated TSV..."
    CURATED_TMP="${METADATA_DIR}/metadata_curated.tmp"

    # (the values converted to NULL are recorded per domain and joined in NULL-VALUES-NCBI.tsv at the end)
    NULL_ROWS="${METADATA_DIR}/null-values.part.tsv"
    rm -f "${NULL_ROWS}"
    dataformat tsv genome --force --inputfile "${REPORT_FILE}" --fields "${FIELDS}" \
        | merge_rows_by_accession \
        | format_tsv 1 "${NULL_ROWS}" "${DOMAIN}-NCBI-METADATA/{genbank,refseq}-metadata.tsv" \
        | awk -F'\t' -v OFS='\t' '
            NR == 1 {
                for (i = 1; i <= NF; i++) if ($i == "ASSEMBLY_NOTES") c = i
                print $0, "GENOME_TYPE"
                next
            }
            { print $0, ((c && index(tolower($c), "derived from metagenome") > 0) ? "mag" : "isolate_genome") }
        ' > "${CURATED_TMP}"

    # 5. Split into GenBank (GCA_) and RefSeq (GCF_), adding the accession of the paired assembly of the other
    #    database: NCBI_REFSEQ_ASSEMBLY_ACCESSION in the GenBank table and NCBI_GENBANK_ASSEMBLY_ACCESSION in the
    #    RefSeq table. It is NULL when there is no paired assembly of the right database or when NCBI says that the two
    #    are different (...ARE_DIFFERENT = true: no correspondence). Every GCF_ has a GCA_, not every GCA_ has a GCF_.
    #    The tables are written under temporary names and renamed only at the end: their presence works as the
    #    checkpoint of the domain.
    awk -F'\t' -v OFS='\t' -v gb="${GENBANK_TSV}.tmp" -v rs="${REFSEQ_TSV}.tmp" '
        NR == 1 {
            for (i = 1; i <= NF; i++) {
                if ($i == "ASSEMBLY_PAIRED_ASSEMBLY_ACCESSION") p = i
                if ($i == "ASSEMBLY_PAIRED_ASSEMBLY_REFSEQ_GENBANK_ARE_DIFFERENT") d = i
            }
            if (!p || !d) { print "paired-assembly columns not found in the curated table" > "/dev/stderr"; exit 1 }
            print $0, "NCBI_REFSEQ_ASSEMBLY_ACCESSION" > gb
            print $0, "NCBI_GENBANK_ASSEMBLY_ACCESSION" > rs
            next
        }
        {
            different = (tolower($d) == "true")
            if ($1 ~ /^GCA_/) { print $0, (!different && $p ~ /^GCF_/ ? $p : "NULL") > gb; n_gb++ }
            else if ($1 ~ /^GCF_/) { print $0, (!different && $p ~ /^GCA_/ ? $p : "NULL") > rs; n_rs++ }
        }
        END { printf "%d\t%d\n", n_gb, n_rs > "/dev/stderr" }
    ' "${CURATED_TMP}" 2> "${CURATED_TMP}.counts" || die "[${DOMAIN}] $(cat "${CURATED_TMP}.counts")"

    read -r N_GENBANK N_REFSEQ < "${CURATED_TMP}.counts"
    mv "${GENBANK_TSV}.tmp" "${GENBANK_TSV}"
    mv "${REFSEQ_TSV}.tmp" "${REFSEQ_TSV}"
    rm -f "${CURATED_TMP}" "${CURATED_TMP}.counts"
    rm -rf "${CHUNKS_DIR}"

    log "message" "[${DOMAIN}] GenBank: ${N_GENBANK} assemblies -> ${GENBANK_TSV}"
    log "message" "[${DOMAIN}] RefSeq: ${N_REFSEQ} assemblies -> ${REFSEQ_TSV}"

    # 6. Complete table (every field of the assembly reports), only with --complete-table
    if [[ "${COMPLETE_TABLE}" -eq 1 ]]; then
        log "message" "[${DOMAIN}] Writing the complete metadata table (every field)..."
        build_complete_table "${REPORT_FILE}" "${COMPLETE_TSV}"
        log "message" "[${DOMAIN}] Complete metadata: $(count_records "${COMPLETE_TSV}") assemblies, $(head -n 1 "${COMPLETE_TSV}" | awk -F'\t' '{ print NF }') columns -> ${COMPLETE_TSV}"
    fi
done

# Values converted to NULL in the curated tables of both domains
NULL_PARTS=()
for DOMAIN in "${PF_DOMAINS[@]}"; do
    NULL_PARTS+=("$(pf_ncbi_metadata_dir "${OUTPUT_DIR}" "${DOMAIN}")/null-values.part.tsv")
done
pf_write_null_mapping "${OUTPUT_DIR}/NULL-VALUES-NCBI.tsv" "${NULL_PARTS[@]}"
log "message" "Values converted to NULL (empty or invalid): ${OUTPUT_DIR}/NULL-VALUES-NCBI.tsv"

{
    echo "NCBI reference data downloaded on $(date +"%Y-%m-%d %H:%M:%S")"
    echo "assembly_source=${DATASETS_SOURCE}"
    echo "datasets=$(datasets --version 2>&1 | head -n 1)"
    echo "format=${PF_REFDB_FORMAT_NCBI}"
} > "${COMPLETED_MARKER}"

log "message" "NCBI reference data download completed successfully!"
