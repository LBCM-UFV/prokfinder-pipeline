#!/usr/bin/env bash
#
# make-fixture.sh - writes the reference database fixture of the tests (tests/data/refdb and tests/data/refdb-raw)
#
# Copies, from a complete reference database folder (~/prokfinder-refdb, written by "main-prokfinder.sh setup"), only
# the rows of a small set of genomes; the complete folder is only read. The genomes are:
#   - every assembly of the GTDB genera Thermus and Pyrococcus (GTDB tables) and of the NCBI genera of the same name
#   - GCA_964347835.1 (archaeon of an unnamed GTDB species, s__CAYFZR01 sp964347835, without BacDive data)
#   - controls that the thermophile filters must keep out or let in: Deinococcus radiodurans R1 (mesophile of the
#     phylum of Thermus), Thermotoga maritima MSB8 (thermophilic bacterium outside Thermus) and Methanocaldococcus
#     jannaschii DSM 2661 (thermophilic archaeon outside Pyrococcus). Species with many BacDive strains (e.g.,
#     Escherichia coli) are avoided: every strain of a species is needed to rebuild its BacDive row
# The GenBank and RefSeq assemblies of the same genome (same accession number) are both kept.
#
# Output (same layout as the reference database folder):
#   <out>/refdb/       formatted tables used by search-genomes and download-wf: NCBI metadata (GenBank and RefSeq) and
#                      fetch.txt, BacDive tables, GTDB taxonomy and metadata, checkpoints, NULL-VALUES-<DB>.tsv
#   <out>/refdb-raw/   the raw files of the same rows, from which setup rebuilds the tables: NCBI assembly reports
#                      (JSONL), fetch.txt and an NCBI taxdump with only the taxa of these genomes (and their
#                      ancestors); BacDive strains (JSONL) and list of IDs; GTDB taxonomy and metadata (.tsv.gz)
#   <out>/FIXTURE.txt  what was copied, from where and when
#
# It reads files of several GB (the NCBI assembly reports of Bacteria have ~16 GB): on the UFV cluster, run it in a
# PBS job, not on the login node.
#
# Usage: make-fixture.sh --refdb <reference_db_dir> -o <output_dir>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "${SCRIPT_DIR}/../../lib/common.sh"

GENERA="Thermus Pyrococcus"
EXTRA_ACCESSIONS="GCA_964347835.1 GCA_000008565.1 GCA_000008545.1 GCA_000091665.1"

usage() {
    awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "${BASH_SOURCE[0]}"
    exit "${1:-0}"
}

REFDB=""
OUT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --refdb)   REFDB="${2:-}"; shift 2 ;;
        -o)        OUT="${2:-}"; shift 2 ;;
        -h|--help) usage 0 ;;
        *)         die "Unknown option: '$1'. Use $(basename "$0") -h to see the options." ;;
    esac
done
[[ -n "${REFDB}" && -n "${OUT}" ]] || die "--refdb and -o are required. Use $(basename "$0") -h to see the options."
for DB in NCBI BACDIVE GTDB; do
    [[ -f "$(pf_completed_marker "${REFDB}/${DB}")" ]] || die "${REFDB}/${DB} is not a complete reference database."
done

make_temp_dir WORK
FIX="${OUT}/refdb"
RAW="${OUT}/refdb-raw"
rm -rf "${FIX}" "${RAW}"
NUMS="${WORK}/accession-numbers.txt"   # accession numbers without prefix (000005845.2): GenBank + RefSeq
TAXIDS="${WORK}/taxids.txt"            # NCBI TaxIDs of the genomes and of their BacDive strains

# Writes the rows of <table> whose first column has its accession number in NUMS (header kept)
# Usage: rows_of_genomes <table> > <slice>
rows_of_genomes() {
    awk -F'\t' 'NR == FNR { keep[$1] = 1; next }
        FNR == 1 { print; next }
        { a = $1; sub(/^(RS_|GB_)?GC[AF]_/, "", a) } (a in keep)' "${NUMS}" "$1"
}

############ 1. GENOMES ################

log "message" "Selecting the genomes (GTDB and NCBI genera: ${GENERA}; extra: ${EXTRA_ACCESSIONS})..."
{
    for DOMAIN in "${PF_DOMAINS[@]}"; do
        TABLE="$(pf_gtdb_taxonomy_table "${REFDB}/GTDB" "${DOMAIN}")"
        awk -F'\t' -v genera=" ${GENERA} " -v c="$(require_column "${TABLE}" GTDB_GENUS)" \
            'FNR > 1 && index(genera, " " $c " ") { print $1 }' "${TABLE}"
        for SOURCE in genbank refseq; do
            TABLE="$(pf_ncbi_metadata_table "${REFDB}/NCBI" "${DOMAIN}" "${SOURCE}")"
            awk -F'\t' -v genera=" ${GENERA} " -v c="$(require_column "${TABLE}" NCBI_GENUS)" \
                'FNR > 1 && index(genera, " " $c " ") { print $1 }' "${TABLE}"
        done
    done
    printf '%s\n' ${EXTRA_ACCESSIONS}
} | sed -E 's/^GC[AF]_//' | LC_ALL=C sort -u > "${NUMS}"
log "message" "  $(wc -l < "${NUMS}") accession numbers"

############ 2. FORMATTED TABLES (refdb) ################

log "message" "NCBI tables..."
for DOMAIN in "${PF_DOMAINS[@]}"; do
    for SOURCE in genbank refseq; do
        TABLE="$(pf_ncbi_metadata_table "${REFDB}/NCBI" "${DOMAIN}" "${SOURCE}")"
        SLICE="$(pf_ncbi_metadata_table "${FIX}/NCBI" "${DOMAIN}" "${SOURCE}")"
        mkdir -p "$(dirname "${SLICE}")"
        rows_of_genomes "${TABLE}" > "${SLICE}"
        log "message" "  ${DOMAIN} ${SOURCE}: $(count_records "${SLICE}") assemblies"
    done
    # fetch.txt: <url> TAB 0 TAB data/<accession>/<file>
    FETCH="$(pf_ncbi_fetch_file "${FIX}/NCBI" "${DOMAIN}")"
    mkdir -p "$(dirname "${FETCH}")"
    awk -F'\t' 'NR == FNR { keep[$1] = 1; next }
        { split($3, p, "/"); a = p[2]; sub(/^GC[AF]_/, "", a) } (a in keep)' \
        "${NUMS}" "$(pf_ncbi_fetch_file "${REFDB}/NCBI" "${DOMAIN}")" > "${FETCH}"
done

# TaxIDs of the genomes: the organism, its strain and species link BacDive (.link); every rank goes to the taxdump
# (.ncbi)
for KIND in link ncbi; do
    for DOMAIN in "${PF_DOMAINS[@]}"; do
        for SOURCE in genbank refseq; do
            SLICE="$(pf_ncbi_metadata_table "${FIX}/NCBI" "${DOMAIN}" "${SOURCE}")"
            awk -F'\t' -v kind="${KIND}" 'NR == 1 {
                    for (i = 1; i <= NF; i++)
                        if ($i ~ /^(ORGANISM_TAXONOMIC_ID|NCBI_SPECIES_TAXID|NCBI_STRAIN_TAXID)$/ || (kind == "ncbi" && $i ~ /^NCBI_.*_TAXID$/)) c[i] = 1
                    next
                }
                { for (i in c) if ($i ~ /^[0-9]+$/) print $i }' "${SLICE}"
        done
    done | LC_ALL=C sort -u > "${TAXIDS}.${KIND}"
done

log "message" "BacDive tables..."
mkdir -p "${FIX}/BACDIVE/BACDIVE-FORMATTED-TSV"
# Strains (bacdive_id) with one of the TaxIDs of the genomes, and every TaxID of these strains (taxdump). The species
# table keeps only the TaxIDs of the genomes: every strain of these TaxIDs is in the fixture, so their rows are the
# same in the complete and in the rebuilt table (a rebuilt table also has partial rows of the other TaxIDs of the
# strains)
awk -F'\t' 'NR == FNR { t[$1] = 1; next }
    FNR > 1 { n = split($2, x, ";"); for (i = 1; i <= n; i++) if (x[i] in t) { print $1; next } }' \
    "${TAXIDS}.link" "$(pf_bacdive_table "${REFDB}/BACDIVE")" | LC_ALL=C sort -u > "${WORK}/bacdive-ids.txt"
awk -F'\t' 'NR == FNR { b[$1] = 1; next }
    FNR > 1 && ($1 in b) { n = split($2, x, ";"); for (i = 1; i <= n; i++) print x[i] }' \
    "${WORK}/bacdive-ids.txt" "$(pf_bacdive_table "${REFDB}/BACDIVE")" | LC_ALL=C sort -u > "${TAXIDS}.bacdive"
LC_ALL=C sort -u "${TAXIDS}.ncbi" "${TAXIDS}.bacdive" > "${TAXIDS}"
for TABLE in "$(pf_bacdive_table "${REFDB}/BACDIVE")" "$(pf_bacdive_strain_table "${REFDB}/BACDIVE")"; do
    awk -F'\t' 'NR == FNR { b[$1] = 1; next } FNR == 1 || ($1 in b)' "${WORK}/bacdive-ids.txt" "${TABLE}" \
        > "${FIX}/BACDIVE/BACDIVE-FORMATTED-TSV/$(basename "${TABLE}")"
done
awk -F'\t' 'NR == FNR { t[$1] = 1; next } FNR == 1 || ($1 in t)' "${TAXIDS}.link" \
    "$(pf_bacdive_species_table "${REFDB}/BACDIVE")" > "$(pf_bacdive_species_table "${FIX}/BACDIVE")"
log "message" "  $(wc -l < "${WORK}/bacdive-ids.txt") strains, $(count_records "$(pf_bacdive_species_table "${FIX}/BACDIVE")") TaxIDs"

log "message" "GTDB tables..."
mkdir -p "${FIX}/GTDB"
cp "$(pf_gtdb_version_file "${REFDB}/GTDB")" "${FIX}/GTDB/"
for DOMAIN in "${PF_DOMAINS[@]}"; do
    for TABLE in "$(pf_gtdb_taxonomy_table "${REFDB}/GTDB" "${DOMAIN}")" "$(pf_gtdb_metadata_table "${REFDB}/GTDB" "${DOMAIN}")"; do
        SLICE="${FIX}/GTDB/${TABLE#"${REFDB}/GTDB/"}"
        mkdir -p "$(dirname "${SLICE}")"
        rows_of_genomes "${TABLE}" > "${SLICE}"
    done
    log "message" "  ${DOMAIN}: $(count_records "$(pf_gtdb_taxonomy_table "${FIX}/GTDB" "${DOMAIN}")") genomes"
done

# Checkpoints and NULL mappings of the complete databases (the formats are the same)
for DB in NCBI BACDIVE GTDB; do
    { cat "$(pf_completed_marker "${REFDB}/${DB}")"; echo "fixture=tests/data/make-fixture.sh $(date +%Y-%m-%d)"; } \
        > "$(pf_completed_marker "${FIX}/${DB}")"
    cp "${REFDB}/${DB}/NULL-VALUES-${DB}.tsv" "${FIX}/${DB}/"
done

############ 3. RAW FILES (refdb-raw) ################

log "message" "NCBI assembly reports (several GB are read)..."
for DOMAIN in "${PF_DOMAINS[@]}"; do
    IN_DIR="$(pf_ncbi_metadata_dir "${REFDB}/NCBI" "${DOMAIN}")"
    OUT_DIR="$(pf_ncbi_metadata_dir "${RAW}/NCBI" "${DOMAIN}")"
    mkdir -p "${OUT_DIR}" "$(pf_ncbi_genomes_dir "${RAW}/NCBI" "${DOMAIN}")"
    # (fast pre-filter by fixed strings, then the accession of each record is checked)
    sed -E 's/.*/"accession":"GCA_&"\n"accession":"GCF_&"/' "${NUMS}" > "${WORK}/patterns.txt"
    LC_ALL=C grep -F -f "${WORK}/patterns.txt" "${IN_DIR}/assembly_data_report.jsonl" \
        | awk 'NR == FNR { keep[$1] = 1; next }
            match($0, /"accession":"GC[AF]_[0-9]+[.][0-9]+"/) {
                a = substr($0, RSTART + 17, RLENGTH - 18); if (a in keep) print }' "${NUMS}" - \
        > "${OUT_DIR}/assembly_data_report.jsonl" || true
    cp "$(pf_ncbi_fetch_file "${FIX}/NCBI" "${DOMAIN}")" "$(pf_ncbi_fetch_file "${RAW}/NCBI" "${DOMAIN}")"
    log "message" "  ${DOMAIN}: $(wc -l < "${OUT_DIR}/assembly_data_report.jsonl") assembly reports"
done

log "message" "NCBI taxdump with only the taxa of the genomes and their ancestors..."
TAXDUMP_IN="$(pf_ncbi_taxdump_dir "${REFDB}/NCBI")"
TAXDUMP_OUT="$(pf_ncbi_taxdump_dir "${RAW}/NCBI")"
mkdir -p "${TAXDUMP_OUT}"
# TaxIDs merged into another: the new TaxID is kept too
awk -F'\t[|]\t?' 'NR == FNR { t[$1] = 1; next } ($1 in t) { print $2 }' "${TAXIDS}" "${TAXDUMP_IN}/merged.dmp" \
    | cat - "${TAXIDS}" | LC_ALL=C sort -u > "${WORK}/taxids-with-merged.txt"
awk -F'\t[|]\t' 'NR == FNR { want[$1] = 1; next }
    { parent[$1] = $2 }
    END {
        for (w in want) { t = w; while (t != "" && !(t in keep)) { keep[t] = 1; if (t == parent[t]) break; t = parent[t] } }
        for (t in keep) print t
    }' "${WORK}/taxids-with-merged.txt" "${TAXDUMP_IN}/nodes.dmp" \
    | LC_ALL=C sort -n > "${WORK}/closure.txt"
for FILE in nodes names; do
    awk -F'\t[|]\t' 'NR == FNR { k[$1] = 1; next } ($1 in k)' "${WORK}/closure.txt" "${TAXDUMP_IN}/${FILE}.dmp" \
        > "${TAXDUMP_OUT}/${FILE}.dmp"
done
awk -F'\t[|]\t?' 'NR == FNR { t[$1] = 1; next } ($1 in t)' "${TAXIDS}" "${TAXDUMP_IN}/merged.dmp" > "${TAXDUMP_OUT}/merged.dmp"
awk -F'\t[|]' 'NR == FNR { t[$1] = 1; next } ($1 in t)' "${TAXIDS}" "${TAXDUMP_IN}/delnodes.dmp" > "${TAXDUMP_OUT}/delnodes.dmp"
log "message" "  $(wc -l < "${TAXDUMP_OUT}/nodes.dmp") taxa"

log "message" "BacDive strains..."
BRUTE_IN="$(pf_bacdive_brute_dir "${REFDB}/BACDIVE")"
BRUTE_OUT="$(pf_bacdive_brute_dir "${RAW}/BACDIVE")"
mkdir -p "${BRUTE_OUT}"
awk -F'\t' 'NR == FNR { b[$1] = 1; next } FNR == 1 || ($1 in b)' "${WORK}/bacdive-ids.txt" \
    "${BRUTE_IN}/advsearch_bacdive.tsv" > "${BRUTE_OUT}/advsearch_bacdive.tsv"
# one strain per line: {"id":"<bacdive_id>","data":{...}}
cat "${BRUTE_IN}"/batch_*.jsonl | awk 'NR == FNR { b[$1] = 1; next }
    match($0, /^[{]"id":"[0-9]+"/) { id = substr($0, 8, RLENGTH - 8); if (id in b) print }' \
    "${WORK}/bacdive-ids.txt" - > "${BRUTE_OUT}/batch_00000.jsonl"
: > "${BRUTE_OUT}/list_download_errors.tsv"
log "message" "  $(wc -l < "${BRUTE_OUT}/batch_00000.jsonl") strains"

log "message" "GTDB raw files..."
for DOMAIN in "${PF_DOMAINS[@]}"; do
    PREFIX="$(pf_gtdb_prefix "${DOMAIN}")"
    for KIND in TAXONOMY METADATA; do
        mkdir -p "${RAW}/GTDB/${DOMAIN}-GTDB-${KIND}"
        FILE="${DOMAIN}-GTDB-${KIND}/${PREFIX}_${KIND,,}.tsv.gz"
        # (the taxonomy file has no header: its first line is kept only when it is a genome of the fixture)
        gzip -dc "${REFDB}/GTDB/${FILE}" | awk -F'\t' -v kind="${KIND}" 'NR == FNR { keep[$1] = 1; next }
            FNR == 1 && kind == "METADATA" { print; next }
            { a = $1; sub(/^(RS_|GB_)?GC[AF]_/, "", a) } (a in keep)' "${NUMS}" - | gzip -n > "${RAW}/GTDB/${FILE}"
    done
done
cp "$(pf_gtdb_version_file "${REFDB}/GTDB")" "${RAW}/GTDB/"

for DB in NCBI BACDIVE GTDB; do
    cp "$(pf_completed_marker "${FIX}/${DB}")" "$(pf_completed_marker "${RAW}/${DB}")"
done

############ 4. SUMMARY ################

{
    echo "Reference database fixture of the Prokfinder tests, written by tests/data/make-fixture.sh on $(date +"%Y-%m-%d %H:%M:%S")"
    echo "Source: ${REFDB}"
    for DB in NCBI BACDIVE GTDB; do echo "  ${DB}: $(head -n 1 "$(pf_completed_marker "${REFDB}/${DB}")")"; done
    echo "Genomes: GTDB and NCBI genera ${GENERA}; extra accessions ${EXTRA_ACCESSIONS}"
    echo "Accession numbers: $(wc -l < "${NUMS}"); BacDive strains: $(wc -l < "${WORK}/bacdive-ids.txt"); NCBI TaxIDs: $(wc -l < "${TAXIDS}")"
    for EXTRA in ${EXTRA_ACCESSIONS}; do
        printf '  %s: %s\n' "${EXTRA}" "$(cat "${FIX}"/NCBI/*-NCBI-METADATA/genbank-metadata.tsv | awk -F'\t' -v a="${EXTRA}" '$1 == a { print $2; f = 1 } END { if (!f) print "NOT FOUND in the NCBI GenBank tables" }')"
    done
} > "${OUT}/FIXTURE.txt"
cp "${NUMS}" "${OUT}/fixture-accession-numbers.txt"
cat "${OUT}/FIXTURE.txt"
du -sh "${FIX}" "${RAW}"
log "message" "Fixture written to ${OUT}"
