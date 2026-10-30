#!/usr/bin/env bats
#
# setup with reference databases of an older format: the tables are rebuilt from the raw files already downloaded
# (tests/data/refdb-raw), without any download, and must be the same as the tables of the complete database
# (tests/data/refdb: the same rows, copied by tests/data/make-fixture.sh)

# Programs used by the rebuild of the three databases
REBUILD_PROGRAMS="datasets dataformat taxonkit jq gawk unzip md5sum"

setup_file() {
    load ../helpers/common
    local P
    for P in ${REBUILD_PROGRAMS}; do
        command -v "${P}" >/dev/null 2>&1 || { export PF_SKIP_REASON="${P} not installed"; return 0; }
    done

    export HOME="${BATS_FILE_TMPDIR}/home" TMPDIR="${BATS_FILE_TMPDIR}/tmp" NO_COLOR=1 PF_COLOR=0
    mkdir -p "${HOME}" "${TMPDIR}"
    REFDB="${BATS_FILE_TMPDIR}/refdb"
    cp -r "${PF_FIXTURE_RAW}" "${REFDB}"
    # Checkpoints of an older Prokfinder
    sed -i 's/^format=.*/format=1/' "${REFDB}"/*/COMPLETED-DOWNLOAD.txt

    # Sentinels: any download attempt is recorded (and fails)
    local BIN="${BATS_FILE_TMPDIR}/bin" REAL_DATASETS
    REAL_DATASETS="$(command -v datasets)"
    mkdir -p "${BIN}"
    printf '#!/usr/bin/env bash\necho "curl $*" >> "%s/downloads.txt"\nexit 22\n' "${BATS_FILE_TMPDIR}" > "${BIN}/curl"
    printf '#!/usr/bin/env bash\n[[ "$1" == "--version" || "$1" == "version" ]] && exec "%s" "$@"\necho "datasets $*" >> "%s/downloads.txt"\nexit 1\n' \
        "${REAL_DATASETS}" "${BATS_FILE_TMPDIR}" > "${BIN}/datasets"
    chmod +x "${BIN}"/*

    cd "${BATS_FILE_TMPDIR}" || return 1
    PATH="${BIN}:${PATH}" bash "${PF_MAIN}" --refdb-dir "${REFDB}" -o results setup > setup.log 2>&1
    echo "$?" > setup.status
}

setup() {
    load ../helpers/common
    [[ -z "${PF_SKIP_REASON:-}" ]] || skip "${PF_SKIP_REASON}"
    REFDB="${BATS_FILE_TMPDIR}/refdb"
}

# Usage: assert_rebuilt_table <path inside the reference database folder>
assert_rebuilt_table() {
    assert_file_exists "${REFDB}/$1"
    assert_same_file "${PF_FIXTURE_REFDB}/$1" "${REFDB}/$1"
}

@test "setup finishes and says that the tables are rebuilt from the files already downloaded" {
    run cat "${BATS_FILE_TMPDIR}/setup.log"
    [[ "$(cat "${BATS_FILE_TMPDIR}/setup.status")" -eq 0 ]] || { echo "setup failed:" >&2; echo "${output}" >&2; return 1; }
    local DB
    for DB in NCBI BACDIVE GTDB; do
        assert_output_contains "The ${DB} reference tables were installed by an older version of Prokfinder: they are updated now"
    done
}

@test "nothing was downloaded" {
    assert_file_not_exists "${BATS_FILE_TMPDIR}/downloads.txt" || { cat "${BATS_FILE_TMPDIR}/downloads.txt" >&2; return 1; }
}

@test "checkpoints record the current table formats" {
    local DB
    for DB in NCBI BACDIVE GTDB; do
        run pf_eval "pf_refdb_format_ok '${REFDB}/${DB}' \"\${PF_REFDB_FORMAT_${DB}}\""
        assert_success
    done
}

@test "NCBI: GenBank and RefSeq tables of both domains are the same as in the complete database" {
    local DOMAIN SOURCE
    for DOMAIN in BACTERIA ARCHAEA; do
        for SOURCE in genbank refseq; do
            assert_rebuilt_table "NCBI/${DOMAIN}-NCBI-METADATA/${SOURCE}-metadata.tsv"
        done
    done
}

@test "BacDive: strain and species tables are the same as in the complete database" {
    local TABLE
    for TABLE in BACDIVE_DATA_FORMATTED BACDIVE_CONCATENATED_REFERENCES_FOR_STRAIN; do
        assert_rebuilt_table "BACDIVE/BACDIVE-FORMATTED-TSV/${TABLE}.tsv"
    done
    # The species table of the fixture has only the TaxIDs of its genomes (all their strains are in the fixture); the
    # rebuilt table also has partial rows of the other TaxIDs of these strains, which are not compared
    TABLE="BACDIVE/BACDIVE-FORMATTED-TSV/BACDIVE_CONCATENATED_STRAINS_FOR_SPECIES.tsv"
    awk -F'\t' 'NR == FNR { k[$1] = 1; next } FNR == 1 || ($1 in k)' "${PF_FIXTURE_REFDB}/${TABLE}" "${REFDB}/${TABLE}" \
        > species-rebuilt.tsv
    assert_same_file "${PF_FIXTURE_REFDB}/${TABLE}" species-rebuilt.tsv
}

@test "GTDB: taxonomy and metadata tables are the same as in the complete database" {
    assert_rebuilt_table GTDB/BACTERIA-GTDB-TAXONOMY/bac120_taxonomy_formatted.tsv
    assert_rebuilt_table GTDB/ARCHAEA-GTDB-TAXONOMY/ar53_taxonomy_formatted.tsv
    assert_rebuilt_table GTDB/BACTERIA-GTDB-METADATA/bac120_metadata_formatted.tsv
    assert_rebuilt_table GTDB/ARCHAEA-GTDB-METADATA/ar53_metadata_formatted.tsv
}

@test "NULL-VALUES-<DB>.tsv written for every database" {
    local DB
    for DB in NCBI BACDIVE GTDB; do
        assert_file_exists "${REFDB}/${DB}/NULL-VALUES-${DB}.tsv"
        run awk 'NR == 1' "${REFDB}/${DB}/NULL-VALUES-${DB}.tsv"
        assert_output_equals "$(printf 'SOURCE_TABLE\tCOLUMN\tORIGINAL_VALUE\tRULE\tCONVERTED_TO\tOCCURRENCES')"
    done
}
