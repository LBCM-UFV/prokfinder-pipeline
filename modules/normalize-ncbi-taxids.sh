#!/usr/bin/env bash
#
# normalize-ncbi-taxids.sh - Prokfinder module 0.4: NCBI taxdump and normalization of the NCBI TaxIDs
#
# Downloads the NCBI taxonomy (taxdump) into <refdb_dir>/NCBI/TAXDUMP and checks the NCBI TaxID of every genome of the
# NCBI tables, and of every NCBI TaxID of the BacDive table, against it. The result is written to derived tables next
# to the reference tables (the reference tables themselves are not changed):
#   1. TAXID_STATUS: CURRENT (in nodes.dmp), MERGED (merged.dmp: UPDATED_TAXID is the TaxID it was merged into),
#      DELETED (delnodes.dmp) or INVALID (in no file)
#   2. DELETED and INVALID NCBI TaxIDs are rescued by the organism name (names.dmp, any name class, ends trimmed, case
#      ignored), keeping only Bacteria and Archaea: one TaxID = RESCUED; several = AMBIGUOUS (UPDATED_TAXID is the
#      first one); none = UNRESOLVED (UPDATED_TAXID is NULL: the genome stays in the table but no TaxID filter finds
#      it). The BacDive table has no organism names: its DELETED and INVALID TaxIDs are not rescued
#   3. SPECIES_TAXID (the species the UPDATED_TAXID belongs to) and RANK (rank of the UPDATED_TAXID)
# Everything is written to temporary files and renamed at the end, under a lock; the checkpoint
# (TAXID-NORMALIZATION-COMPLETED.txt) is written last, so an interrupted run leaves none.
#
# Usage: normalize-ncbi-taxids.sh -o <refdb_dir> [--skip-download]
#
# Output:
#   <refdb_dir>/NCBI/TAXDUMP/                                              (names.dmp, nodes.dmp, merged.dmp, delnodes.dmp)
#   <refdb_dir>/NCBI/<DOMAIN>-NCBI-METADATA/<source>-taxid-status.tsv      (ASSEMBLY_ACCESSION, TAXID, TAXID_STATUS,
#                                                                          UPDATED_TAXID, SPECIES_TAXID, RANK, TAXDUMP_DATE)
#   <refdb_dir>/BACDIVE/BACDIVE-FORMATTED-TSV/bacdive-taxid-status.tsv     (ncbi_tax_id, TAXID_STATUS, UPDATED_TAXID,
#                                                                          SPECIES_TAXID, RANK, TAXDUMP_DATE)
#   <refdb_dir>/NCBI/taxid-unresolved.tsv                                  (genomes whose TaxID was not CURRENT/MERGED)
#   <refdb_dir>/NCBI/TAXID-NORMALIZATION-COMPLETED.txt                     (checkpoint: written only at the end)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

############ READING PARAMETERS ################

usage() {
    cat << EOF
Usage: $(basename "$0") -o <refdb_dir> [options]

  -o <refdb_dir>     Reference database directory (the one with NCBI/ and BACDIVE/; required)
  --skip-download    Use the taxdump already in <refdb_dir>/NCBI/TAXDUMP instead of downloading a new one
  -h                 Show this help message

EOF
    exit "${1:-1}"
}

REF_DIR=""
SKIP_DOWNLOAD=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) REF_DIR="${2%/}"; shift 2 ;;
        --skip-download) SKIP_DOWNLOAD=1; shift ;;
        -h|--help) usage 0 ;;
        *) log "error" "Invalid option: $1"; usage ;;
    esac
done

if [[ -z "${REF_DIR}" ]]; then
    log "error" "Reference database directory (-o) is required."
    usage
fi

NCBI_DIR="${REF_DIR}/NCBI"
BACDIVE_DIR="${REF_DIR}/BACDIVE"
[[ -d "${NCBI_DIR}" ]] || die "NCBI reference data not found in ${NCBI_DIR}. Run setup first."

setup_module_log "${NCBI_DIR}/normalize-ncbi-taxids.log"
require_programs awk curl tar

TAXDUMP_URL="https://ftp.ncbi.nlm.nih.gov/pub/taxonomy/taxdump.tar.gz"
TAXDUMP="$(pf_ncbi_taxdump_dir "${NCBI_DIR}")"
TAXID_MARKER="$(pf_taxid_marker "${NCBI_DIR}")"
TAXDUMP_FILES=(names.dmp nodes.dmp merged.dmp delnodes.dmp)

############ LOCK ################

# One normalization at a time per reference database (a job reads the tables while another one writes them)
if command -v flock > /dev/null 2>&1; then
    exec 9> "${REF_DIR}/.taxdump.lock"
    if ! flock -n 9; then
        log "message" "Another process is updating the NCBI taxonomy of ${REF_DIR}; waiting for it..."
        flock 9
    fi
else
    log "warning" "flock not found: nothing prevents two normalizations of ${REF_DIR} at the same time."
fi

# The checkpoint is written last: without it the tables are not trusted (also after an interrupted run)
rm -f "${TAXID_MARKER}"

############ TAXDUMP ################

# Prints the date of the taxdump in use (the server date of the file, or the modification date of names.dmp)
taxdump_date() {
    if [[ -s "${TAXDUMP}/taxdump-date.txt" ]]; then
        awk 'NR == 1' "${TAXDUMP}/taxdump-date.txt"
    else
        date -u -r "${TAXDUMP}/names.dmp" +%F
    fi
}

if [[ "${SKIP_DOWNLOAD}" -eq 1 ]]; then
    for FILE in "${TAXDUMP_FILES[@]}"; do
        [[ -f "${TAXDUMP}/${FILE}" ]] || die "${TAXDUMP}/${FILE} not found. Run: setup --update-taxdump-file"
    done
    log "message" "Using the NCBI taxdump already installed (${TAXDUMP}, $(taxdump_date))."
else
    log "message" "Downloading the NCBI taxdump from ${TAXDUMP_URL}..."
    NEW_DIR="${NCBI_DIR}/TAXDUMP.new"
    rm -rf "${NEW_DIR}"
    mkdir -p "${NEW_DIR}"
    # -R: the file gets the date of the server, which is the date of the taxonomy
    curl -fsSL -R --retry 5 --retry-delay 10 -o "${NEW_DIR}/taxdump.tar.gz" "${TAXDUMP_URL}" \
        || die "Could not download ${TAXDUMP_URL}"
    date -u -r "${NEW_DIR}/taxdump.tar.gz" +%F > "${NEW_DIR}/taxdump-date.txt"
    tar -xzf "${NEW_DIR}/taxdump.tar.gz" -C "${NEW_DIR}" "${TAXDUMP_FILES[@]}" \
        || die "Could not extract ${NEW_DIR}/taxdump.tar.gz"
    rm -f "${NEW_DIR}/taxdump.tar.gz"
    # (merged.dmp and delnodes.dmp are only checked to exist: they are empty in a taxonomy without any of them)
    for FILE in names.dmp nodes.dmp; do
        [[ -s "${NEW_DIR}/${FILE}" ]] || die "${FILE} is empty in the downloaded taxdump."
    done
    # Swap (the old folder is removed only after the new one is in place)
    rm -rf "${TAXDUMP}.old"
    [[ ! -d "${TAXDUMP}" ]] || mv "${TAXDUMP}" "${TAXDUMP}.old"
    mv "${NEW_DIR}" "${TAXDUMP}"
    rm -rf "${TAXDUMP}.old"
    log "message" "NCBI taxdump of $(taxdump_date) installed in ${TAXDUMP}"
fi
TAXDUMP_DATE="$(taxdump_date)"

############ NORMALIZATION ################

make_temp_dir WORK
JOBS="${WORK}/jobs.tsv"
: > "${JOBS}"
OUTPUTS=()

# Jobs: <label> <input table> <output table> <key column> <TaxID column> <name column or ->
add_job() {
    local LABEL="$1" INPUT="$2" OUTPUT="$3"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${LABEL}" "${INPUT}" "${OUTPUT}.tmp" "$4" "$5" "$6" >> "${JOBS}"
    OUTPUTS+=("${OUTPUT}")
}

for DOMAIN in "${PF_DOMAINS[@]}"; do
    for SOURCE in genbank refseq; do
        TABLE="$(pf_ncbi_metadata_table "${NCBI_DIR}" "${DOMAIN}" "${SOURCE}")"
        [[ -f "${TABLE}" ]] || die "${TABLE} not found. Run setup first."
        add_job "${DOMAIN}-${SOURCE}" "${TABLE}" "$(pf_ncbi_taxid_status_table "${NCBI_DIR}" "${DOMAIN}" "${SOURCE}")" \
            ASSEMBLY_ACCESSION ORGANISM_TAXONOMIC_ID ORGANISM_NAME
    done
done
BACDIVE_TABLE="$(pf_bacdive_species_table "${BACDIVE_DIR}")"
if [[ -f "${BACDIVE_TABLE}" ]]; then
    add_job "BACDIVE" "${BACDIVE_TABLE}" "$(pf_bacdive_taxid_status_table "${BACDIVE_DIR}")" ncbi_tax_id ncbi_tax_id -
else
    log "warning" "BacDive table not found (${BACDIVE_TABLE}): its TaxIDs are not normalized."
fi

REPORT="$(pf_ncbi_taxid_report "${NCBI_DIR}")"
COUNTS="${WORK}/counts.tsv"
: > "${COUNTS}"

log "message" "Normalizing the NCBI TaxIDs of $(awk 'END { print NR }' "${JOBS}") tables against the taxdump of ${TAXDUMP_DATE}..."

# One awk process reads the taxdump once and then every table (twice: the first pass collects the names to rescue).
awk -F'\t' -v OFS='\t' -v jobs="${JOBS}" -v taxdump="${TAXDUMP}" -v date="${TAXDUMP_DATE}" \
    -v report="${REPORT}.tmp" -v counts="${COUNTS}" '
function trim(s) { gsub(/^[ \t\r]+|[ \t\r]+$/, "", s); return s }
function value(v) { return (v == "" ? "NULL" : v) }

# 1 if the TaxID is inside Bacteria (2) or Archaea (2157)
function in_prokaryotes(t,   n) {
    for (n = 0; n < 64 && (t in parent); n++) {
        if (t == "2" || t == "2157") return 1
        if (parent[t] == t) return 0
        t = parent[t]
    }
    return 0
}

# species the TaxID belongs to ("" when it is above species rank)
function species_of(t,   n) {
    for (n = 0; n < 64 && (t in parent); n++) {
        if (rank[t] == "species") return t
        if (parent[t] == t) return ""
        t = parent[t]
    }
    return ""
}

# Sets status and updated for a TaxID and (lowercase) name; the rescue by name only when the names were loaded
function classify(t, lname, rescue,   u, n, m, i, c, list, first) {
    status = ""; updated = ""
    if (t ~ /^[0-9]+$/) {
        if (t in parent) { status = "CURRENT"; updated = t }
        else if (t in merged) {
            u = merged[t]
            for (n = 0; n < 16 && !(u in parent) && (u in merged); n++) u = merged[u]
            if (u in parent) { status = "MERGED"; updated = u } else status = "DELETED"
        }
        else if (t in deleted) status = "DELETED"
        else status = "INVALID"
    } else status = "INVALID"
    if ((status == "DELETED" || status == "INVALID") && rescue) {
        c = 0
        if (lname != "" && (lname in cand)) {
            m = split(cand[lname], list, " ")
            for (i = 1; i <= m; i++) if (in_prokaryotes(list[i])) { if (++c == 1) first = list[i] }
        }
        if (c == 1) { status = "RESCUED"; updated = first }
        else if (c > 1) { status = "AMBIGUOUS"; updated = first }
        else status = "UNRESOLVED"
    }
}

# Reads one table: phase 1 collects the names of the TaxIDs to rescue, phase 2 writes the derived table
function read_table(j, phase,   line, f, nf, i, key_col, tax_col, name_col, t, lname, sp, out_line) {
    if ((getline line < in_file[j]) <= 0) { print "cannot read " in_file[j] > "/dev/stderr"; exit 1 }
    nf = split(line, f, "\t")
    key_col = 0; tax_col = 0; name_col = 0
    for (i = 1; i <= nf; i++) {
        if (f[i] == key_name[j]) key_col = i
        if (f[i] == tax_name[j]) tax_col = i
        if (f[i] == nam_name[j]) name_col = i
    }
    if (!key_col || !tax_col || (nam_name[j] != "-" && !name_col)) {
        print "columns " key_name[j] "/" tax_name[j] "/" nam_name[j] " not found in " in_file[j] > "/dev/stderr"; exit 1
    }
    if (phase == 2) {
        out_line = key_name[j]
        if (key_col != tax_col) out_line = out_line OFS "TAXID"
        print out_line, "TAXID_STATUS", "UPDATED_TAXID", "SPECIES_TAXID", "RANK", "TAXDUMP_DATE" > out_file[j]
    }
    while ((getline line < in_file[j]) > 0) {
        nf = split(line, f, "\t")
        t = f[tax_col]
        lname = (name_col ? tolower(trim(f[name_col])) : "")
        if (phase == 1) {
            classify(t, lname, 0)
            if ((status == "DELETED" || status == "INVALID") && lname != "") want[lname] = 1
            continue
        }
        classify(t, lname, name_col != 0)
        sp = (updated != "" ? species_of(updated) : "")
        out_line = f[key_col]
        if (key_col != tax_col) out_line = out_line OFS value(t)
        print out_line, status, value(updated), value(sp), (updated != "" ? value(rank[updated]) : "NULL"), date > out_file[j]
        n_status[label[j], status]++
        statuses[status] = 1
        if (status != "CURRENT" && status != "MERGED")
            print label[j], f[key_col], value(t), (name_col ? value(trim(f[name_col])) : "NULL"), status, value(updated) > report
    }
    close(in_file[j])
}

BEGIN {
    nj = 0
    while ((getline line < jobs) > 0) {
        split(line, f, "\t"); nj++
        label[nj] = f[1]; in_file[nj] = f[2]; out_file[nj] = f[3]; key_name[nj] = f[4]; tax_name[nj] = f[5]; nam_name[nj] = f[6]
    }
    close(jobs)

    # taxdump: nodes.dmp "<taxid> | <parent> | <rank> | ...", merged.dmp "<old> | <new> |", delnodes.dmp "<taxid> |"
    while ((getline line < (taxdump "/nodes.dmp")) > 0) { split(line, f, /\t\|\t?/); parent[f[1]] = f[2]; rank[f[1]] = f[3] }
    while ((getline line < (taxdump "/merged.dmp")) > 0) { split(line, f, /\t\|\t?/); merged[f[1]] = f[2] }
    while ((getline line < (taxdump "/delnodes.dmp")) > 0) { split(line, f, /\t\|\t?/); deleted[f[1]] = 1 }
    close(taxdump "/nodes.dmp"); close(taxdump "/merged.dmp"); close(taxdump "/delnodes.dmp")

    for (j = 1; j <= nj; j++) read_table(j, 1)

    # names.dmp "<taxid> | <name> | <unique name> | <class> |": only the names to rescue are kept
    while ((getline line < (taxdump "/names.dmp")) > 0) {
        split(line, f, /\t\|\t?/)
        lname = tolower(trim(f[2]))
        if ((lname in want) && !((lname SUBSEP f[1]) in seen)) {
            seen[lname, f[1]] = 1
            cand[lname] = (lname in cand ? cand[lname] " " f[1] : f[1])
        }
    }
    close(taxdump "/names.dmp")

    print "TABLE", "KEY", "TAXID", "ORGANISM_NAME", "TAXID_STATUS", "UPDATED_TAXID" > report
    for (j = 1; j <= nj; j++) read_table(j, 2)
    for (j = 1; j <= nj; j++) for (s in statuses) if ((label[j], s) in n_status) print label[j], s, n_status[label[j], s] > counts
    close(counts)
}' || die "The normalization of the TaxIDs failed."

# Rename the derived tables and the report, then write the checkpoint
for OUTPUT in "${OUTPUTS[@]}"; do
    mv "${OUTPUT}.tmp" "${OUTPUT}"
done
mv "${REPORT}.tmp" "${REPORT}"

log "message" "TaxID status per table (CURRENT, MERGED, RESCUED, AMBIGUOUS, UNRESOLVED, DELETED, INVALID):"
sort -k1,1 -k2,2 "${COUNTS}" | awk -F'\t' '{ printf "    %-24s %-10s %d\n", $1, $2, $3 }' >&2
UNRESOLVED_N="$(awk -F'\t' 'END { print (NR > 0 ? NR - 1 : 0) }' "${REPORT}")"
if [[ "${UNRESOLVED_N}" -gt 0 ]]; then
    log "warning" "${UNRESOLVED_N} TaxID(s) are not CURRENT or MERGED (rescued by name, ambiguous or unresolved): see ${REPORT}. Unresolved genomes stay in the tables but are not found by the TaxID filters."
fi

{
    echo "NCBI TaxID normalization finished on $(date +"%Y-%m-%d %H:%M:%S")"
    echo "date=$(date +%F)"
    echo "taxdump_date=${TAXDUMP_DATE}"
    awk -F'\t' '{ printf "status.%s.%s=%d\n", $1, $2, $3 }' "${COUNTS}"
} > "${TAXID_MARKER}"

log "message" "NCBI TaxID normalization completed successfully!"
