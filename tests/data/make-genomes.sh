#!/usr/bin/env bash
#
# make-genomes.sh - writes the genome files of the download-wf tests (tests/data/genomes)
#
# Downloads a few genomes of the fixture with the NCBI Datasets CLI and keeps only their first ~300 kb (contigs in the
# order of the file; the last one kept is cut), so that the tests stay small and fast while Pyrodigal still runs in
# single mode (>= 100 kb). The fake "datasets" of tests/bin copies these files when download-wf "downloads" them.
#   GCA_000091545.1  Thermus thermophilus HB8 (representative genome of its GTDB species)
#   GCA_000008125.1  Thermus thermophilus HB27 (same GTDB species as HB8)
#   GCA_000011105.1  Pyrococcus horikoshii OT3 (archaeon: BUSCO lineage archaea)
#   GCA_964347835.1  archaeon of an unnamed GTDB species (s__CAYFZR01 sp964347835), MAG
#   GCA_061250155.1  Thermus sp. that is not in the GTDB tables (classified by the fake GTDB-Tk ani_rep)
#   GCA_040289965.1  Thermus sp. MAG with hundreds of short contigs, not in the GTDB tables: only its shortest contigs
#                    are kept whole, up to ~300 kb (a fragmented genome, with N50 < 5 kb: it fails the structural
#                    evaluation)
#
# Usage: make-genomes.sh [-o <output_dir>]   (default: tests/data/genomes; needs the network)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "${SCRIPT_DIR}/../../lib/common.sh"

ACCESSIONS="GCA_000091545.1 GCA_000008125.1 GCA_000011105.1 GCA_964347835.1 GCA_061250155.1 GCA_040289965.1"
FRAGMENTED="GCA_040289965.1"
MAX_BP=300000

usage() {
    awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "${BASH_SOURCE[0]}"
    exit "${1:-0}"
}

OUT="${SCRIPT_DIR}/genomes"
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o)        OUT="${2:-}"; shift 2 ;;
        -h|--help) usage 0 ;;
        *)         die "Unknown option: '$1'. Use $(basename "$0") -h to see the options." ;;
    esac
done
require_programs datasets unzip gzip seqkit

make_temp_dir WORK
# shellcheck disable=SC2086
datasets download genome accession ${ACCESSIONS} --include genome --no-progressbar --filename "${WORK}/genomes.zip"
unzip -q "${WORK}/genomes.zip" -d "${WORK}/unzipped"

mkdir -p "${OUT}"
for ACC in ${ACCESSIONS}; do
    FILE="$(find "${WORK}/unzipped/ncbi_dataset/data/${ACC}" -name '*_genomic.fna' ! -name '*_from_genomic.fna' | awk 'NR == 1')"
    [[ -n "${FILE}" ]] || die "${ACC} was not downloaded."
    if [[ " ${FRAGMENTED} " == *" ${ACC} "* ]]; then
        # The shortest whole contigs, up to MAX_BP bases
        seqkit sort --quiet --by-length "${FILE}" | seqkit fx2tab \
            | awk -F'\t' -v max="${MAX_BP}" 'total + length($2) > max { exit } { total += length($2); print }' \
            | seqkit tab2fx --line-width 80
    else
        # The sequence up to MAX_BP bases, in lines of 80
        awk -v max="${MAX_BP}" '
            /^>/ { if (total >= max) exit; print; next }
            {
                left = max - total
                if (left <= 0) next
                line = substr($0, 1, left)
                total += length(line)
                print line
            }' "${FILE}"
    fi | gzip -9n > "${OUT}/${ACC}.fna.gz"
    log "message" "${ACC}: $(gzip -dc "${OUT}/${ACC}.fna.gz" | awk '/^>/ { n++; next } { bp += length($0) } END { printf "%d contigs, %d bp", n, bp }')"
done
log "message" "Genomes written to ${OUT}."
