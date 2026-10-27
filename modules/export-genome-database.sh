#!/usr/bin/env bash
#
# export-genome-database.sh - Prokfinder module 11: self-contained genome database
#
# Builds a folder that can be moved, shared and used by other programs (annotation, k-mer databases, trees) without
# broken links: the genomes, the proteins and the genes of the requested accessions (always compressed), the metadata
# of those genomes with relative paths, the versions and parameters of the run and the MD5 of every file.
# A genome file that is already compressed is hard-linked (a copy when the link is not possible, e.g. another file
# system), so the database costs almost no extra space; a link to the original is never a symbolic link.
#
# Re-execution: a genome whose clean genome file did not change and whose files are in the database is not exported
# again; files of accessions that left the list are removed; the MD5 of the unchanged files are reused. The small
# files (metadata, versions, parameters, README) are written on every run.
#
# Usage: export-genome-database.sh -m <genome_metadata.tsv> -l <accession_list> -g <genes_dir> -f <final_results_dir>
#                                  -o <database_dir> [-c <criterion>] [-p <threads>]
#   <genome_metadata.tsv> must have the column CLEAN_GENOME_FILE; <genes_dir> has <ACCESSION>.faa and .gff (Pyrodigal)
#
# Output:
#   <database_dir>/genomes/<ACCESSION>.fna.gz, proteins/<ACCESSION>.faa.gz, genes/<ACCESSION>.gff.gz
#   <database_dir>/genome-database-metadata.tsv   the columns of genome-metadata.tsv, without the absolute paths
#                                                 (RAW_GENOME_FILE, CLEAN_GENOME_FILE, PROTEIN_FILE,
#                                                 TAXONOMIC_LEAF_DIR) and with GENOME_FILE, PROTEIN_FILE and
#                                                 GENE_FILE (paths relative to <database_dir>)
#   <database_dir>/versions.tsv, parameters.tsv, README.txt, MD5SUMS.txt (check: md5sum -c MD5SUMS.txt)
#   <database_dir>/export-cache.tsv, export-genome-database.log

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

usage() {
    cat << EOF
Usage: $(basename "$0") -m <genome_metadata.tsv> -l <accession_list> -g <genes_dir> -f <final_results_dir> -o <database_dir> [-c <criterion>] [-p <threads>]

  -m <file>   Genome metadata table (with CLEAN_GENOME_FILE)
  -l <file>   Accessions exported (one per line)
  -g <dir>    Folder with the Pyrodigal files <ACCESSION>.faa and <ACCESSION>.gff
  -f <dir>    Folder with versions.tsv and parameters.tsv of the run (FINAL-RESULTS)
  -o <dir>    Folder of the genome database
  -c <text>   Which genomes were exported, for the README (default: "the genomes of the accession list")
  -p <n>      Genomes exported at the same time (default: 4)
EOF
    exit "${1:-1}"
}

METADATA=""
ACC_LIST=""
GENES_DIR=""
FINAL_DIR=""
OUT_DIR=""
CRITERION="the genomes of the accession list"
THREADS=4

while [[ $# -gt 0 ]]; do
    case "$1" in
        -m) METADATA="$2"; shift 2 ;;
        -l) ACC_LIST="$2"; shift 2 ;;
        -g) GENES_DIR="${2%/}"; shift 2 ;;
        -f) FINAL_DIR="${2%/}"; shift 2 ;;
        -o) OUT_DIR="${2%/}"; shift 2 ;;
        -c) CRITERION="$2"; shift 2 ;;
        -p) THREADS="$2"; shift 2 ;;
        -h|--help) usage 0 ;;
        *) log "error" "Invalid option: $1"; usage ;;
    esac
done

if [[ -z "${METADATA}" || -z "${ACC_LIST}" || -z "${GENES_DIR}" || -z "${FINAL_DIR}" || -z "${OUT_DIR}" ]]; then
    log "error" "Options -m, -l, -g, -f and -o are required."
    usage
fi
[[ -f "${METADATA}" ]] || die "Metadata table not found: ${METADATA}"
[[ -f "${ACC_LIST}" ]] || die "Accession list not found: ${ACC_LIST}"
[[ -d "${GENES_DIR}" ]] || die "Genes folder not found: ${GENES_DIR}"
[[ "${THREADS}" =~ ^[1-9][0-9]*$ ]] || die "The number of threads must be a positive integer (got '${THREADS}')."

mkdir -p "${OUT_DIR}/genomes" "${OUT_DIR}/proteins" "${OUT_DIR}/genes"
setup_module_log "${OUT_DIR}/export-genome-database.log"
OUT_DIR="$(absolute_path "${OUT_DIR}")"
GENES_DIR="$(absolute_path "${GENES_DIR}")"
export OUT_DIR GENES_DIR

C_CLEAN="$(require_column "${METADATA}" CLEAN_GENOME_FILE)"

make_temp_dir WORK_DIR
tr -d '\r' < "${ACC_LIST}" | awk 'NF { print $1 }' | LC_ALL=C sort -u > "${WORK_DIR}/accessions.txt"
[[ -s "${WORK_DIR}/accessions.txt" ]] || die "The accession list is empty: ${ACC_LIST}"

# 1. Clean genome file of each accession: <accession> <TAB> <file> <TAB> <mtime>
GENOMES="${WORK_DIR}/genomes.tsv"
awk -F'\t' -v OFS='\t' -v acc_file="${WORK_DIR}/accessions.txt" -v c_clean="${C_CLEAN}" '
    BEGIN { while ((getline a < acc_file) > 0) want[a] = 1; close(acc_file) }
    NR > 1 && ($1 in want) { print $1, $c_clean }
' "${METADATA}" > "${WORK_DIR}/genome_files.tsv"
while IFS=$'\t' read -r ACC FILE; do
    [[ -f "${FILE}" ]] || die "Clean genome file of ${ACC} not found: ${FILE}"
    printf '%s\t%s\t%s\n' "${ACC}" "${FILE}" "$(file_mtime "${FILE}")"
done < "${WORK_DIR}/genome_files.tsv" > "${GENOMES}"

N_GENOMES="$(count_lines "${GENOMES}")"
N_LIST="$(count_lines "${WORK_DIR}/accessions.txt")"
[[ "${N_GENOMES}" -eq "${N_LIST}" ]] || die "$((N_LIST - N_GENOMES)) accession(s) of the list are not in ${METADATA}."

# 2. Genomes to export: not in the cache with the same mtime, or with a file missing in the database
CACHE="${OUT_DIR}/export-cache.tsv"
[[ -s "${CACHE}" ]] || printf 'ASSEMBLY_ACCESSION\tFILE_MTIME\n' > "${CACHE}"
awk -F'\t' -v dir="${OUT_DIR}" '
    NR == FNR { if (FNR > 1) done[$1 SUBSEP $2] = 1; next }
    {
        missing = 0
        if (system("test -s \"" dir "/genomes/" $1 ".fna.gz\"") != 0) missing = 1
        if (system("test -s \"" dir "/proteins/" $1 ".faa.gz\"") != 0) missing = 1
        if (system("test -s \"" dir "/genes/" $1 ".gff.gz\"") != 0) missing = 1
    }
    !(($1 SUBSEP $3) in done) || missing
' "${CACHE}" "${GENOMES}" > "${WORK_DIR}/pending.tsv"
N_PENDING="$(count_lines "${WORK_DIR}/pending.tsv")"
log "message" "Genome database: ${N_GENOMES} genome(s); $((N_GENOMES - N_PENDING)) reused; ${N_PENDING} to export (${THREADS} at a time)."

# Exports the genome, the proteins and the genes of one accession (run by xargs, one process per genome)
export_genome() {
    local ACC="$1"
    local SRC="$2"
    local GENES="${GENES_DIR}/${ACC}"
    local DEST="${OUT_DIR}/genomes/${ACC}.fna.gz"
    local TMP
    [[ -s "${GENES}.faa" && -s "${GENES}.gff" ]] || { echo "No Pyrodigal files of ${ACC} in ${GENES_DIR}" >&2; return 1; }

    TMP="${OUT_DIR}/genomes/.${ACC}.fna.gz.tmp"
    if [[ "${SRC}" == *.gz ]]; then
        if [[ ! "${SRC}" -ef "${DEST}" ]]; then
            rm -f "${TMP}"
            ln "${SRC}" "${TMP}" 2> /dev/null || cp -p "${SRC}" "${TMP}"
            mv -f "${TMP}" "${DEST}"
        fi
    else
        gzip -n -c "${SRC}" > "${TMP}"
        mv -f "${TMP}" "${DEST}"
    fi

    TMP="${OUT_DIR}/proteins/.${ACC}.faa.gz.tmp"
    gzip -n -c "${GENES}.faa" > "${TMP}"
    mv -f "${TMP}" "${OUT_DIR}/proteins/${ACC}.faa.gz"

    TMP="${OUT_DIR}/genes/.${ACC}.gff.gz.tmp"
    gzip -n -c "${GENES}.gff" > "${TMP}"
    mv -f "${TMP}" "${OUT_DIR}/genes/${ACC}.gff.gz"
}
export -f export_genome

if [[ "${N_PENDING}" -gt 0 ]]; then
    cut -f1,2 "${WORK_DIR}/pending.tsv" | tr '\t\n' '\0\0' \
        | xargs -0 -n 2 -P "${THREADS}" bash -c 'set -e; export_genome "$1" "$2"' _ \
        || die "The export of some genomes failed (see the messages above)."
    awk -F'\t' -v OFS='\t' '{ print $1, $3 }' "${WORK_DIR}/pending.tsv" > "${WORK_DIR}/new_rows.tsv"
    update_cache "${CACHE}" "${WORK_DIR}/new_rows.tsv"
fi

# 3. Files of accessions that left the list, and temporary files of an interrupted run
find "${OUT_DIR}/genomes" "${OUT_DIR}/proteins" "${OUT_DIR}/genes" -type f -name '.*.tmp' -delete
declare -A WANTED=()
while IFS= read -r ACC; do
    WANTED["${ACC}"]=1
done < "${WORK_DIR}/accessions.txt"
N_REMOVED=0
for KIND in genomes:fna.gz proteins:faa.gz genes:gff.gz; do
    for FILE in "${OUT_DIR}/${KIND%%:*}"/*; do
        [[ -f "${FILE}" ]] || continue
        ACC="$(basename "${FILE}")"
        ACC="${ACC%."${KIND#*:}"}"
        if [[ -z "${WANTED[${ACC}]:-}" ]]; then
            rm -f "${FILE}"
            N_REMOVED=$((N_REMOVED + 1))
        fi
    done
done
[[ "${N_REMOVED}" -eq 0 ]] || log "message" "Removed ${N_REMOVED} file(s) of genomes that are no longer exported."

# 4. Metadata of the exported genomes, with paths relative to the database folder
awk -F'\t' -v OFS='\t' -v acc_file="${WORK_DIR}/accessions.txt" '
    BEGIN {
        while ((getline a < acc_file) > 0) want[a] = 1
        close(acc_file)
        n = split("RAW_GENOME_FILE CLEAN_GENOME_FILE PROTEIN_FILE TAXONOMIC_LEAF_DIR", d, " ")
        for (i = 1; i <= n; i++) drop[d[i]] = 1
    }
    function others(   out, k) {
        out = ""
        for (k = 1; k <= nk; k++) out = out OFS $(keep[k])
        return out
    }
    NR == 1 {
        nk = 0
        for (i = 2; i <= NF; i++) if (!($i in drop)) keep[++nk] = i
        print $1, "GENOME_FILE", "PROTEIN_FILE", "GENE_FILE" others()
        next
    }
    ($1 in want) { print $1, "genomes/" $1 ".fna.gz", "proteins/" $1 ".faa.gz", "genes/" $1 ".gff.gz" others() }
' "${METADATA}" > "${WORK_DIR}/metadata.tsv"
{
    awk 'NR == 1' "${WORK_DIR}/metadata.tsv"
    awk 'NR > 1' "${WORK_DIR}/metadata.tsv" | LC_ALL=C sort -t $'\t' -k1,1
} > "${OUT_DIR}/genome-database-metadata.tsv.tmp"
mv "${OUT_DIR}/genome-database-metadata.tsv.tmp" "${OUT_DIR}/genome-database-metadata.tsv"

# 5. Versions and parameters of the run, and the README
for NAME in versions parameters; do
    if [[ -f "${FINAL_DIR}/${NAME}.tsv" ]]; then
        cp "${FINAL_DIR}/${NAME}.tsv" "${OUT_DIR}/${NAME}.tsv"
    else
        log "warning" "${FINAL_DIR}/${NAME}.tsv not found: it is not in the genome database."
    fi
done

PROKFINDER_VERSION_USED="$(awk -F'\t' '$1 == "prokfinder_version" { print $2 }' "${OUT_DIR}/parameters.tsv" 2> /dev/null || true)"
cat > "${OUT_DIR}/README.txt" << EOF
Prokfinder genome database
==========================

${N_GENOMES} prokaryote genome(s): ${CRITERION}.
Built by Prokfinder ${PROKFINDER_VERSION_USED:-(version in parameters.tsv)} (https://github.com/LBCM-UFV/prokfinder-pipeline).

Files
  genomes/<ACCESSION>.fna.gz      genome sequences (contigs shorter than the minimum length removed), gzip
  proteins/<ACCESSION>.faa.gz     proteins predicted with Pyrodigal, gzip
  genes/<ACCESSION>.gff.gz        gene coordinates predicted with Pyrodigal (GFF3), gzip
  genome-database-metadata.tsv    one row per genome: NCBI assembly metadata, BacDive phenotypes, quality (CheckM2,
                                  BUSCO, seqkit), GTDB taxonomy and dereplication; GENOME_FILE, PROTEIN_FILE and
                                  GENE_FILE are the paths of the files above, relative to this folder
  versions.tsv                    versions of the programs and databases used
  parameters.tsv                  command line and options of the run
  MD5SUMS.txt                     MD5 of every file; check with: md5sum -c MD5SUMS.txt

This folder has no links to other places: it can be moved or copied.

How to cite
  Cite Prokfinder and the programs and databases listed in versions.tsv (NCBI, BacDive, GTDB, CheckM2, BUSCO,
  GTDB-Tk, Pyrodigal, seqkit, skDER or CiDDER, as used in the run).
EOF

# 6. MD5 of every file; the lines of the genome files that were not exported again are reused
(
    cd "${OUT_DIR}"
    find genomes proteins genes -type f ! -name '.*' | LC_ALL=C sort > "${WORK_DIR}/data_files.txt"
    awk -F'\t' '{ print "genomes/" $1 ".fna.gz"; print "proteins/" $1 ".faa.gz"; print "genes/" $1 ".gff.gz" }' \
        "${WORK_DIR}/pending.tsv" > "${WORK_DIR}/redo.txt"
    [[ -f MD5SUMS.txt ]] || : > MD5SUMS.txt
    awk -v redo="${WORK_DIR}/redo.txt" -v keep_out="${WORK_DIR}/md5_kept.txt" -v hash_out="${WORK_DIR}/md5_to_hash.txt" '
        BEGIN { while ((getline f < redo) > 0) again[f] = 1; close(redo) }
        FILENAME == "MD5SUMS.txt" { old[substr($0, 35)] = $0; next }
        {
            if (($0 in old) && !($0 in again)) print old[$0] > keep_out
            else print $0 > hash_out
        }
        END { close(keep_out); close(hash_out) }
    ' MD5SUMS.txt "${WORK_DIR}/data_files.txt"
    {
        printf '%s\n' genome-database-metadata.tsv README.txt
        [[ ! -f versions.tsv ]] || echo versions.tsv
        [[ ! -f parameters.tsv ]] || echo parameters.tsv
    } >> "${WORK_DIR}/md5_to_hash.txt"
    [[ -f "${WORK_DIR}/md5_kept.txt" ]] || : > "${WORK_DIR}/md5_kept.txt"
    xargs -r -d '\n' -n 20 -P "${THREADS}" md5sum < "${WORK_DIR}/md5_to_hash.txt" > "${WORK_DIR}/md5_new.txt"
    cat "${WORK_DIR}/md5_kept.txt" "${WORK_DIR}/md5_new.txt" | LC_ALL=C sort -k2,2 > MD5SUMS.txt.tmp
    mv MD5SUMS.txt.tmp MD5SUMS.txt
)

log "message" "Genome database ready: ${N_GENOMES} genome(s) in ${OUT_DIR} (check: cd it and run md5sum -c MD5SUMS.txt)"
