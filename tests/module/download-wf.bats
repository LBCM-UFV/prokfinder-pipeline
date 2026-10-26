#!/usr/bin/env bats
#
# download-wf (modules 2-10) on the reference database fixture and the genomes of tests/data/genomes (first ~300 kb of
# each genome, tests/data/make-genomes.sh). seqkit and Pyrodigal are the real programs; datasets, checkm2, busco,
# gtdbtk, skder and cidder are the fake programs of tests/bin, with the results of tests/data/fake-programs.
#   HB8 GCA_000091545.1 and HB27 GCA_000008125.1   Thermus thermophilus (GTDB table), ANI 98.66 between them
#   GCA_000011105.1                                Pyrococcus horikoshii (archaeon: BUSCO lineage archaea)
#   GCA_964347835.1                                archaeon of an unnamed GTDB species (GTDB table)
#   GCA_061250155.1                                Thermus sp. not in the GTDB tables (GTDB-Tk ani_rep)
#   GCA_040289965.1                                fragmented Thermus sp. MAG (N50 < 5 kb; CheckM2 42% / 7%)
#   GCA_000008565.1                                D. radiodurans R1: no genome file (failed download)

HB8="GCA_000091545.1"
HB27="GCA_000008125.1"
P_HORIKOSHII="GCA_000011105.1"
UNNAMED_ARCHAEON="GCA_964347835.1"
NOT_IN_GTDB="GCA_061250155.1"
FRAGMENTED="GCA_040289965.1"
NO_GENOME_FILE="GCA_000008565.1"
ACCESSIONS="${HB8},${HB27},${P_HORIKOSHII},${UNNAMED_ARCHAEON},${NOT_IN_GTDB},${FRAGMENTED},${NO_GENOME_FILE}"

# Environment of a run with the fake programs: tests/bin first in the PATH, a CheckM2 database file that only needs
# to exist, a GTDB-Tk reference package folder (named r232, as on the UFV cluster) with only the ANI radii of the
# species used, a copy of the reference database fixture (download-wf writes the BUSCO lineages into <refdb>/BUSCO),
# and the log of the calls
# Usage: fake_env <dir>
fake_env() {
    export PATH="${PF_TESTS}/bin:${PATH}"
    export PF_FAKE_LOG="$1/fake-calls.log"
    export CHECKM2DB="$1/checkm2-fake.dmnd"
    export GTDBTK_DATA_PATH="$1/r232"
    : > "${CHECKM2DB}"
    mkdir -p "${GTDBTK_DATA_PATH}/radii"
    cp "${PF_TESTS}/data/fake-programs/gtdb_radii.tsv" "${GTDBTK_DATA_PATH}/radii/"
    if [[ ! -d "$1/refdb" ]]; then
        cp -r "${PF_FIXTURE_REFDB}" "$1/refdb"
    fi
    REFDB="$1/refdb"
}

# Runs search-genomes (the genomes of the fixture) and download-wf with 2 CPUs and 4 GB, writing to <results>
# Usage: run_wf <results> [download-wf options...]
run_wf() {
    local RESULTS="$1"
    shift
    bash "${PF_MAIN}" --refdb-dir "${REFDB}" -o "${RESULTS}" -p 2 --memory 4 search-genomes -a "${ACCESSIONS}" \
        download-wf "$@"
}

setup_file() {
    load ../helpers/common
    export PYTHONUSERBASE="${PYTHONUSERBASE:-${HOME}/.local}"
    export HOME="${BATS_FILE_TMPDIR}/home" TMPDIR="${BATS_FILE_TMPDIR}/tmp" NO_COLOR=1 PF_COLOR=0
    unset PROKFINDER_LOG PROKFINDER_COMMON_LOADED PBS_JOBID NCPUS PF_FAKE_FAIL PF_FAKE_ANI_CLOSEST PF_FAKE_CIDDER_VERSION
    mkdir -p "${HOME}" "${TMPDIR}"
    cd "${BATS_FILE_TMPDIR}" || return 1
    fake_env "${BATS_FILE_TMPDIR}"
    # One run with the default options, read by the tests that only check its results
    run_wf base > base.log 2>&1 || { cat base.log >&2; return 1; }
}

setup() {
    load ../helpers/common
    pf_test_setup
    unset PF_FAKE_FAIL PF_FAKE_ANI_CLOSEST PF_FAKE_CIDDER_VERSION
    fake_env "${BATS_TEST_TMPDIR}"
    BASE="${BATS_FILE_TMPDIR}/base"
}

metadata() { echo "$1/OUTPUT/GENOME-METADATA/genome-metadata.tsv"; }

# Copy of a table with the temporary folders of the tests written as <TMP> (absolute paths change in every run)
# Usage: portable_tsv <tsv>
portable_tsv() {
    local OUT
    OUT="${BATS_TEST_TMPDIR}/portable-$(basename "$1")"
    sed -e "s#${BATS_FILE_TMPDIR}#<TMP>#g" -e "s#${BATS_TEST_TMPDIR}#<TMP>#g" "$1" > "${OUT}"
    echo "${OUT}"
}

# Number of calls of the fake programs that match an extended regular expression (e.g., '^checkm2 predict')
# Usage: count_calls <regex> [log]
count_calls() {
    local LOG="${2:-${PF_FAKE_LOG}}"
    [[ -f "${LOG}" ]] || { echo 0; return 0; }
    awk -v re="$1" '$0 ~ re { n++ } END { print n + 0 }' "${LOG}"
}

# Usage: assert_value <tsv> <accession> <column> <expected value>
assert_value() {
    local FOUND
    FOUND="$(tsv_value "$1" "$2" "$3")"
    if [[ "${FOUND}" != "$4" ]]; then
        printf '%s of %s in %s: expected "%s", found "%s"\n' "$3" "$2" "$1" "$4" "${FOUND}" >&2
        return 1
    fi
}

############ ONE RUN WITH THE DEFAULT OPTIONS ################

@test "download-wf: the tables of every step are the expected ones (tests/expected/download-wf)" {
    run cat "${BATS_FILE_TMPDIR}/base.log"
    assert_output_contains "Prokfinder finished successfully."
    assert_expected_tsv download-wf/genome-metadata.tsv "$(portable_tsv "$(metadata "${BASE}")")"
    assert_expected_tsv download-wf/contig-filtering.tsv "$(portable_tsv "${BASE}/OUTPUT/GENOME-QUALITY/contig-filtering.tsv")"
    assert_expected_tsv download-wf/genome-quality.tsv "${BASE}/OUTPUT/GENOME-QUALITY/genome-quality.tsv"
    assert_expected_tsv download-wf/taxonomy-classification.tsv "${BASE}/OUTPUT/GENOME-TAXONOMY/taxonomy-classification.tsv"
    assert_expected_tsv download-wf/dereplication-summary.tsv "${BASE}/OUTPUT/GENOME-DEREPLICATION/dereplication-summary.tsv"
    assert_expected_tsv download-wf/selection-funnel.tsv "${BASE}/OUTPUT/FINAL-RESULTS/STATISTICS/TABLES/selection-funnel.tsv"
    assert_expected_tsv download-wf/high-quality-selected-genomes.txt \
        "$(portable_tsv "${BASE}/OUTPUT/FINAL-RESULTS/high-quality-selected-genomes.txt")"
}

@test "download-wf: versions.tsv and parameters.tsv record the programs, databases and options of the run" {
    local FINAL="${BASE}/OUTPUT/FINAL-RESULTS"
    # (the versions of the real programs seqkit, Pyrodigal, R and of the code change: only the fake ones are compared)
    # (without the Rscript row: R is installed on the maintainer machines, not in the CI)
    grep -v "^Rscript" "${FINAL}/versions.tsv" > "${BATS_TEST_TMPDIR}/versions-without-r.tsv" || true
    assert_expected_tsv download-wf/versions.tsv "${BATS_TEST_TMPDIR}/versions-without-r.tsv" VERSION SOURCE
    assert_value "${FINAL}/versions.tsv" checkm2 VERSION 1.1.0
    assert_value "${FINAL}/versions.tsv" busco VERSION "BUSCO 6.1.0"
    assert_value "${FINAL}/versions.tsv" gtdbtk VERSION "gtdbtk: version 2.7.2 Copyright 2017 Pierre-Alain Chaumeil, Aaron Mussig and Donovan Parks"
    assert_value "${FINAL}/versions.tsv" skder VERSION "skDER v1.3.6"
    assert_value "${FINAL}/versions.tsv" GTDB VERSION "v232 2026-10-24 09:31:51 (format 4)"
    assert_value "${FINAL}/versions.tsv" gtdbtk-reference VERSION r232
    assert_value "${FINAL}/versions.tsv" checkm2-database VERSION checkm2-fake.dmnd
    assert_value "${FINAL}/versions.tsv" busco-lineages VERSION "archaea_odb12,bacteria_odb12"
    assert_expected_tsv download-wf/parameters.tsv "$(portable_tsv "${FINAL}/parameters.tsv")" VALUE
    assert_value "${FINAL}/parameters.tsv" --derep-ani VALUE 99.5
    assert_value "${FINAL}/parameters.tsv" --max-n-bases VALUE 100000
    assert_value "${FINAL}/parameters.tsv" --threads VALUE 2
    assert_value "${FINAL}/parameters.tsv" --memory VALUE 4gb
    assert_value "${FINAL}/parameters.tsv" selected_genomes VALUE 7
}

@test "download-wf: --skip-busco and --derep-method cidder change the programs listed in versions.tsv" {
    local FINAL="${BATS_TEST_TMPDIR}/r/OUTPUT/FINAL-RESULTS"
    run run_wf "${BATS_TEST_TMPDIR}/r" --skip-busco --derep-method cidder
    assert_success
    run cut -f1 "${FINAL}/versions.tsv"
    refute_output_contains "busco"
    assert_output_contains "cidder"
    refute_output_contains "skder"
    assert_value "${FINAL}/parameters.tsv" --skip-busco VALUE yes
    assert_value "${FINAL}/parameters.tsv" --derep-method VALUE cidder
}

@test "download-wf: a genome without a file is DOWNLOAD_FAILED and the others go on" {
    assert_value "$(metadata "${BASE}")" "${NO_GENOME_FILE}" DOWNLOAD_STATUS DOWNLOAD_FAILED
    assert_value "$(metadata "${BASE}")" "${HB8}" DOWNLOAD_STATUS DOWNLOADED
    run cat "${BATS_FILE_TMPDIR}/base.log"
    assert_output_contains "1 genome(s) could not be downloaded in this run"
    assert_file_exists "${BASE}/OUTPUT/GENOME-FILES/raw_genomes/${HB8}.fna"
}

@test "download-wf: the fragmented genome fails the structural evaluation (N50) and gets no genes nor CheckM2" {
    local M
    M="$(metadata "${BASE}")"
    assert_value "${M}" "${FRAGMENTED}" STRUCTURE_STATUS FAILED
    assert_value "${M}" "${FRAGMENTED}" STRUCTURE_FAILED_CRITERIA "N50<5000"
    assert_value "${M}" "${FRAGMENTED}" QC_STATUS FAILED
    assert_value "${M}" "${FRAGMENTED}" GENE_PREDICTION_STATUS NULL
    assert_file_not_exists "${BASE}/OUTPUT/GENOME-GENES/${FRAGMENTED}.faa"
    run grep -c "${FRAGMENTED}" "${BASE}/OUTPUT/GENOME-QUALITY/checkm2-cache.tsv"
    assert_output_equals "0"
}

@test "download-wf: genes are predicted once (Pyrodigal single mode) and used by CheckM2 and BUSCO" {
    local M
    M="$(metadata "${BASE}")"
    assert_value "${M}" "${HB8}" GENE_CALLING_MODE single
    assert_value "${M}" "${HB8}" TRANSLATION_TABLE 11
    assert_file_exists "${BASE}/OUTPUT/GENOME-GENES/${HB8}.faa"
    assert_value "${M}" "${HB8}" CHECKM2_COMPLETENESS 99.99
    run count_calls '^checkm2 predict --genes ' "${BATS_FILE_TMPDIR}/fake-calls.log"
    assert_output_equals "1"
}

@test "download-wf: BUSCO lineage from the NCBI domain (archaea_odb12 / bacteria_odb12, BUSCO 6)" {
    local M
    M="$(metadata "${BASE}")"
    assert_value "${M}" "${P_HORIKOSHII}" BUSCO_LINEAGE archaea_odb12
    assert_value "${M}" "${UNNAMED_ARCHAEON}" BUSCO_LINEAGE archaea_odb12
    assert_value "${M}" "${HB8}" BUSCO_LINEAGE bacteria_odb12
    assert_value "${M}" "${HB8}" BUSCO_COMPLETENESS 93.1
    assert_value "${M}" "${HB8}" BUSCO_TOTAL 116
    run count_calls '^busco --in ' "${BATS_FILE_TMPDIR}/fake-calls.log"
    assert_output_equals "2"
}

@test "download-wf: GTDB taxonomy from the tables, and from GTDB-Tk ani_rep for a genome not in them" {
    local M T
    M="$(metadata "${BASE}")"
    T="${BASE}/OUTPUT/GENOME-TAXONOMY/taxonomy-classification.tsv"
    assert_value "${M}" "${HB8}" GTDB_CLASSIFICATION_METHOD GTDB_TABLE
    assert_value "${M}" "${UNNAMED_ARCHAEON}" GTDB_SPECIES "CAYFZR01 sp964347835"
    assert_value "${M}" "${NOT_IN_GTDB}" GTDB_CLASSIFICATION_METHOD GTDBTK_ANI
    assert_value "${M}" "${NOT_IN_GTDB}" GTDB_SPECIES "Thermus scotoductus"
    assert_value "${M}" "${NOT_IN_GTDB}" GTDB_TAXONOMY_SOURCE "GTDB-Tk 2.7.2 ani_rep (r232)"
    assert_value "${T}" "${NOT_IN_GTDB}" ANI_REFERENCE_GENOME GCF_000381045.1
    assert_value "${T}" "${NOT_IN_GTDB}" ANI 96.12
    assert_value "${T}" "${NOT_IN_GTDB}" ANI_THRESHOLD 95.00
    # Only the genome that is not in the GTDB tables goes to ani_rep
    run count_calls '^gtdbtk ani_rep ' "${BATS_FILE_TMPDIR}/fake-calls.log"
    assert_output_equals "1"
    run cat "${BASE}/OUTPUT/GENOME-TAXONOMY/GTDBTK-RESULTS/gtdbtk-ani-cache.tsv"
    assert_output_contains "${NOT_IN_GTDB}"
    refute_output_contains "${HB8}"
}

@test "download-wf: hierarchy by GTDB species and skDER inside each species (ANI 98.66 < 99.5: both kept)" {
    local M
    M="$(metadata "${BASE}")"
    assert_value "${M}" "${HB8}" TAXONOMIC_LEAF_RANK SPECIES
    assert_file_exists "${BASE}/OUTPUT/GENOME-DIR-HIERARCHY/Bacteria/Deinococcota/Deinococci/Deinococcales/Thermaceae/Thermus/Thermus_thermophilus/genomes-files-symlink.txt"
    assert_value "${M}" "${HB8}" REPRESENTATIVE_GENOME yes
    assert_value "${M}" "${HB27}" REPRESENTATIVE_GENOME yes
    assert_value "${M}" "${HB8}" LEAF_GENOME_COUNT 2
    # skDER runs only in the leaf with more than one genome
    run count_calls '^skder --genomes ' "${BATS_FILE_TMPDIR}/fake-calls.log"
    assert_output_equals "1"
    run awk 'END { print NR - 1 }' "${BASE}/OUTPUT/FINAL-RESULTS/high-quality-selected-genomes.txt"
    assert_output_equals "5"
}

@test "download-wf: final tables and graphs are written" {
    local DIR="${BASE}/OUTPUT/FINAL-RESULTS/STATISTICS"
    for TABLE in qc-status gtdb-classification-methods genomes-per-gtdb-phylum genomes-per-gtdb-species; do
        assert_file_exists "${DIR}/TABLES/${TABLE}.tsv"
    done
    assert_file_exists "${DIR}/TABLES/all-prokaryote-genomes-status.tsv.gz"
    if command -v Rscript >/dev/null 2>&1; then
        assert_file_exists "${DIR}/GRAPHS/selection-funnel.png"
    fi
}

############ RE-EXECUTION (CACHES) ################

@test "the same command run again reuses every step: no CheckM2, BUSCO, GTDB-Tk nor skDER call" {
    run_wf results
    cp "$(metadata results)" first.tsv
    local RAW="results/OUTPUT/GENOME-FILES/raw_genomes/${HB8}.fna"
    local MTIME
    MTIME="$(stat -c %Y "${RAW}")"
    : > "${PF_FAKE_LOG}"
    run run_wf results
    assert_success
    for CALL in '^checkm2 predict' '^busco --in' '^gtdbtk ani_rep' '^skder --genomes'; do
        run count_calls "${CALL}"
        assert_output_equals "0"
    done
    # Only the genome that failed is downloaded again; the others are kept
    [[ "$(stat -c %Y "${RAW}")" -eq "${MTIME}" ]] || { echo "${RAW} was downloaded again" >&2; return 1; }
    assert_same_file first.tsv "$(metadata results)"
}

@test "re-execution: the genome that failed the download is downloaded in the next run" {
    run_wf results
    mkdir genomes
    cp "${PF_TESTS}"/data/genomes/*.fna.gz genomes/
    cp "genomes/${HB8}.fna.gz" "genomes/${NO_GENOME_FILE}.fna.gz"
    : > "${PF_FAKE_LOG}"
    PF_FAKE_GENOMES="${BATS_TEST_TMPDIR}/genomes" run run_wf results
    assert_success
    assert_value "$(metadata results)" "${NO_GENOME_FILE}" DOWNLOAD_STATUS DOWNLOADED
    # Only the new genome goes through CheckM2
    run grep '^checkm2 predict' "${PF_FAKE_LOG}"
    assert_success
    run count_calls '^checkm2 predict'
    assert_output_equals "1"
    run cat "${BATS_TEST_TMPDIR}/results/OUTPUT/GENOME-QUALITY/checkm2-cache.tsv"
    assert_output_contains "${NO_GENOME_FILE}"
}

@test "re-execution: a new --derep-ani runs skDER again, without recomputing quality nor taxonomy (98: HB27 alone)" {
    run_wf results
    : > "${PF_FAKE_LOG}"
    run run_wf results --derep-ani 98
    assert_success
    run count_calls '^skder --genomes .*--percent-identity-cutoff 98 '
    assert_output_equals "1"
    run count_calls '^checkm2 predict|^gtdbtk ani_rep'
    assert_output_equals "0"
    assert_value "$(metadata results)" "${HB27}" REPRESENTATIVE_GENOME yes
    assert_value "$(metadata results)" "${HB8}" REPRESENTATIVE_GENOME no
    assert_value "$(metadata results)" "${HB8}" LEAF_REPRESENTATIVE_COUNT 1
}

@test "re-execution: new quality thresholds are applied without running CheckM2 again" {
    run_wf results
    : > "${PF_FAKE_LOG}"
    run run_wf results --min-completeness 95
    assert_success
    run count_calls '^checkm2 predict'
    assert_output_equals "0"
    assert_value "$(metadata results)" "${UNNAMED_ARCHAEON}" QC_STATUS FAILED
    assert_value "$(metadata results)" "${UNNAMED_ARCHAEON}" QC_FAILED_CRITERIA "COMPLETENESS<95"
    assert_value "$(metadata results)" "${UNNAMED_ARCHAEON}" REPRESENTATIVE_GENOME NULL
}

@test "--force-curation computes again every step after the download" {
    run_wf results
    : > "${PF_FAKE_LOG}"
    run run_wf results --force-curation
    assert_success
    assert_output_contains "Option --force-curation"
    assert_file_exists "results/OUTPUT/GENOME-FILES/raw_genomes/${HB8}.fna"
    run count_calls '^checkm2 predict'
    assert_output_equals "1"
    run count_calls '^skder --genomes'
    assert_output_equals "1"
}

############ OPTIONS ################

@test "--min-n50 0 --min-contig-length 2500: the fragmented genome loses contigs and fails CheckM2" {
    run run_wf results --min-n50 0 --min-contig-length 2500
    assert_success
    local M
    M="$(metadata results)"
    assert_value "${M}" "${FRAGMENTED}" CONTIGS_RAW 114
    run tsv_value "${M}" "${FRAGMENTED}" CONTIGS_CLEAN
    [[ "${output}" -gt 0 && "${output}" -lt 114 ]] || { echo "CONTIGS_CLEAN: ${output}" >&2; return 1; }
    assert_value "${M}" "${FRAGMENTED}" STRUCTURE_STATUS PASSED
    assert_value "${M}" "${FRAGMENTED}" CHECKM2_COMPLETENESS 42.16
    assert_value "${M}" "${FRAGMENTED}" QC_STATUS FAILED
    assert_value "${M}" "${FRAGMENTED}" QC_FAILED_CRITERIA "COMPLETENESS<75;CONTAMINATION>5"
    # A genome that failed CheckM2 is not given to BUSCO
    run grep -c "${FRAGMENTED}" "results/OUTPUT/GENOME-QUALITY/busco-cache.tsv"
    assert_output_equals "0"
}

@test "-z: genome files written with gzip, same quality and taxonomy as without it" {
    run run_wf results -z
    assert_success
    assert_file_exists "results/OUTPUT/GENOME-FILES/raw_genomes/${HB8}.fna.gz"
    assert_file_exists "results/OUTPUT/GENOME-FILES/clean_genomes/${HB8}.fna.gz"
    assert_same_file "${BASE}/OUTPUT/GENOME-QUALITY/genome-quality.tsv" results/OUTPUT/GENOME-QUALITY/genome-quality.tsv
    assert_same_file "${BASE}/OUTPUT/GENOME-TAXONOMY/taxonomy-classification.tsv" \
        results/OUTPUT/GENOME-TAXONOMY/taxonomy-classification.tsv
}

@test "--memory below 18 GB: CheckM2 runs with --lowmem and a warning; with 18 GB, in its normal mode" {
    run cat "${BATS_FILE_TMPDIR}/base.log"
    assert_output_contains "it runs with --lowmem, which may take longer"
    run count_calls '^checkm2 predict .*--lowmem' "${BATS_FILE_TMPDIR}/fake-calls.log"
    assert_output_equals "1"
    run bash "${PF_MAIN}" --refdb-dir "${REFDB}" -o results -p 2 --memory 18 search-genomes -a "${HB8}" download-wf
    assert_success
    refute_output_contains "--lowmem"
    run count_calls '^checkm2 predict .*--lowmem'
    assert_output_equals "0"
}

@test "--skip-busco: BUSCO is not called and its columns are NULL" {
    run run_wf results --skip-busco
    assert_success
    run count_calls '^busco --in'
    assert_output_equals "0"
    assert_value "$(metadata results)" "${HB8}" BUSCO_COMPLETENESS NULL
    assert_value "$(metadata results)" "${HB8}" QC_STATUS PASSED
}

@test "--derep-method cidder (CiDDER 1.3.8): reads the proteins predicted by Pyrodigal, nothing is predicted again" {
    run run_wf results --derep-method cidder
    assert_success
    refute_output_contains "cannot read proteomes"
    refute_output_contains "could not use the predicted proteins"
    run count_calls '^cidder --proteomes .*GENOME-GENES/GCA_000008125.1.faa'
    assert_output_equals "1"
    run count_calls '^cidder --genomes'
    assert_output_equals "0"
    local S="results/OUTPUT/GENOME-DEREPLICATION/dereplication-summary.tsv"
    run awk -F'\t' '$12 == "DEREPLICATED" { print $6, $9 }' "${S}"
    assert_output_equals "cidder proteomes"
    run cat results/OUTPUT/GENOME-DEREPLICATION/representative-genomes.tsv
    assert_output_contains "${HB8}"
}

@test "--derep-method cidder (CiDDER 1.3.6): one warning, then the genome files (CiDDER predicts the genes again)" {
    PF_FAKE_CIDDER_VERSION=1.3.6 run run_wf results --derep-method cidder
    assert_success
    assert_output_contains "CiDDER 1.3.6 cannot read proteomes (fixed in 1.3.7)"
    run grep -c "cannot read proteomes" <<< "${output}"
    assert_output_equals "1"
    run count_calls '^cidder --proteomes'
    assert_output_equals "0"
    run count_calls '^cidder --genomes .*clean_genomes/GCA_000008125.1.fna'
    assert_output_equals "1"
    local S="results/OUTPUT/GENOME-DEREPLICATION/dereplication-summary.tsv"
    run awk -F'\t' '$12 == "DEREPLICATED" { print $6, $9 }' "${S}"
    assert_output_equals "cidder genomes"
}

@test "--derep-method cidder: a result made from genome files (CiDDER 1.3.6) is not reused by a CiDDER that reads proteins" {
    PF_FAKE_CIDDER_VERSION=1.3.6 run run_wf results --derep-method cidder
    assert_success
    run run_wf results --derep-method cidder
    assert_success
    run count_calls '^cidder --proteomes'
    assert_output_equals "1"
    run awk -F'\t' '$12 == "DEREPLICATED" { print $9 }' results/OUTPUT/GENOME-DEREPLICATION/dereplication-summary.tsv
    assert_output_equals "proteomes"
}

@test "--derep-method cidder (CiDDER 1.3.8) that fails on the proteins is an error of the lineage, with no re-prediction" {
    PF_FAKE_FAIL="cidder" run run_wf results --derep-method cidder
    assert_success
    assert_output_contains "cidder failed in"
    run count_calls '^cidder --genomes'
    assert_output_equals "0"
    local S="results/OUTPUT/GENOME-DEREPLICATION/dereplication-summary.tsv"
    run awk -F'\t' '$12 == "FAILED" { n++ } END { print n + 0 }' "${S}"
    assert_output_equals "1"
}

@test "--use-gtdbtk-tree: a genome without an ANI match is placed in the GTDB tree (genus leaf)" {
    awk -F'\t' -v OFS='\t' -v a="${NOT_IN_GTDB}" '$1 == a { $6 = "False" } { print }' \
        "${PF_TESTS}/data/fake-programs/gtdbtk-ani-closest.tsv" > ani-closest.tsv
    PF_FAKE_ANI_CLOSEST="${BATS_TEST_TMPDIR}/ani-closest.tsv" run run_wf results --use-gtdbtk-tree
    assert_success
    for STEP in identify align classify; do
        run count_calls "^gtdbtk ${STEP} "
        assert_output_equals "1"
    done
    run count_calls '^gtdbtk classify .*--scratch_dir '
    assert_output_equals "1"
    local M
    M="$(metadata results)"
    assert_value "${M}" "${NOT_IN_GTDB}" GTDB_CLASSIFICATION_METHOD GTDBTK_TREE
    assert_value "${M}" "${NOT_IN_GTDB}" GTDB_GENUS Thermus
    assert_value "${M}" "${NOT_IN_GTDB}" GTDB_SPECIES NULL
    assert_value "${M}" "${NOT_IN_GTDB}" TAXONOMIC_LEAF_RANK GENUS
}

############ PROBLEMS ################

@test "no genome passes the quality filters: the final summary is written and the run ends without error" {
    run run_wf results --min-completeness 100
    assert_success
    assert_output_contains "No genome passed the quality filters."
    assert_file_exists results/OUTPUT/FINAL-RESULTS/STATISTICS/TABLES/selection-funnel.tsv
    run count_calls '^gtdbtk ani_rep|^skder --genomes'
    assert_output_equals "0"
}

@test "CheckM2 failing stops download-wf with the name of the module; the next run goes on from there" {
    PF_FAKE_FAIL=checkm2 run run_wf results
    assert_failure 1
    assert_output_contains "Module evaluate-genome-completeness.sh failed"
    assert_output_contains "failing on purpose"
    : > "${PF_FAKE_LOG}"
    run run_wf results
    assert_success
    run count_calls '^checkm2 predict'
    assert_output_equals "1"
    assert_value "$(metadata results)" "${HB8}" QC_STATUS PASSED
}

@test "download-wf without CHECKM2DB stops before any module, with the dependency error" {
    unset CHECKM2DB
    run run_wf results
    assert_failure 1
    assert_output_contains "CHECKM2DB"
    assert_output_contains "problem(s) found in the dependencies"
    run count_calls '^datasets rehydrate'
    assert_output_equals "0"
}
