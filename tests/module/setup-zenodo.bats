#!/usr/bin/env bats
#
# setup from the Zenodo packages: the fixture (tests/data/refdb) is packed as the packages of a Zenodo record and
# served by the fake curl of tests/bin; no network is used

setup_file() {
    load ../helpers/common
    command -v md5sum >/dev/null 2>&1 || { export PF_SKIP_REASON="md5sum not installed"; return 0; }

    export HOME="${BATS_FILE_TMPDIR}/home" TMPDIR="${BATS_FILE_TMPDIR}/tmp" NO_COLOR=1 PF_COLOR=0
    mkdir -p "${HOME}" "${TMPDIR}"

    # Packages and registry (one package per database, as on Zenodo)
    export PF_FAKE_PACKAGES="${BATS_FILE_TMPDIR}/packages"
    mkdir -p "${PF_FAKE_PACKAGES}"
    REGISTRY="${BATS_FILE_TMPDIR}/registry.tsv"
    printf 'HOST\texample.zenodo.test\nRECORD\t1\n' > "${REGISTRY}"
    local DB FORMAT FILE
    for DB in NCBI BACDIVE GTDB; do
        FORMAT="$(pf_var "PF_REFDB_FORMAT_${DB}")"
        FILE="refdb-${DB,,}-format${FORMAT}.tar.gz"
        tar -czf "${PF_FAKE_PACKAGES}/${FILE}" -C "${PF_FIXTURE_REFDB}" "${DB}"
        printf 'PACKAGE\t%s\t%s\t%s\t%s\n' "${DB}" "${FORMAT}" "${FILE}" \
            "$(md5sum "${PF_FAKE_PACKAGES}/${FILE}" | cut -d' ' -f1)" >> "${REGISTRY}"
    done
    export PF_FAKE_LOG="${BATS_FILE_TMPDIR}/calls.log"

    cd "${BATS_FILE_TMPDIR}" || return 1
    PATH="${PF_TESTS}/bin:${PATH}" bash "${PF_MAIN}" --refdb-dir refdb -o results setup --refdb-registry "${REGISTRY}" \
        > setup.log 2>&1
    echo "$?" > setup.status
}

setup() {
    load ../helpers/common
    [[ -z "${PF_SKIP_REASON:-}" ]] || skip "${PF_SKIP_REASON}"
    REGISTRY="${BATS_FILE_TMPDIR}/registry.tsv"
    REFDB="${BATS_FILE_TMPDIR}/refdb"
    pf_test_setup
    export PF_FAKE_PACKAGES="${BATS_FILE_TMPDIR}/packages"
}

@test "setup downloads and installs the three packages" {
    run cat "${BATS_FILE_TMPDIR}/setup.log"
    [[ "$(cat "${BATS_FILE_TMPDIR}/setup.status")" -eq 0 ]] || { echo "setup failed:" >&2; echo "${output}" >&2; return 1; }
    local DB
    for DB in NCBI BACDIVE GTDB; do
        assert_output_contains "${DB}: downloading"
        assert_same_file "${PF_FIXTURE_REFDB}/${DB}/NULL-VALUES-${DB}.tsv" "${REFDB}/${DB}/NULL-VALUES-${DB}.tsv"
    done
    assert_same_file "${PF_FIXTURE_REFDB}/GTDB/BACTERIA-GTDB-TAXONOMY/bac120_taxonomy_formatted.tsv" \
        "${REFDB}/GTDB/BACTERIA-GTDB-TAXONOMY/bac120_taxonomy_formatted.tsv"
}

@test "the checkpoints have the current format and record the package" {
    local DB
    for DB in NCBI BACDIVE GTDB; do
        run pf_eval "pf_refdb_format_ok '${REFDB}/${DB}' \"\${PF_REFDB_FORMAT_${DB}}\""
        assert_success
        run pf_eval "pf_refdb_from_package '${REFDB}/${DB}'"
        assert_success
    done
}

@test "no temporary folder is left in the reference databases folder" {
    run bash -c "ls -A '${REFDB}' | grep -v '^.download.lock$'"
    assert_output_equals "$(printf 'BACDIVE\nGTDB\nNCBI')"
}

@test "setup again downloads nothing" {
    : > "${PF_FAKE_LOG}"
    run env PATH="${PF_TESTS}/bin:${PATH}" PF_FAKE_LOG="${PF_FAKE_LOG}" bash "${PF_MAIN}" --refdb-dir "${REFDB}" -o results setup \
        --refdb-registry "${REGISTRY}"
    assert_success
    assert_output_contains "NCBI reference data already installed"
    [[ "$(grep -c '^curl' "${PF_FAKE_LOG}" || true)" -eq 0 ]]
}

@test "the installed databases work in a genome search" {
    run bash "${PF_MAIN}" --refdb-dir "${REFDB}" -o search search-genomes --gtdb-taxon g__Thermus
    assert_success
    [[ "$(selected_accessions search | wc -l)" -gt 100 ]]
}

@test "the checkpoints record the MD5 of the package" {
    run grep -c '^package_md5=[0-9a-f]\{32\}$' "${REFDB}/GTDB/COMPLETED-DOWNLOAD.txt"
    assert_output_equals "1"
}

@test "a newer package in the registry replaces the installed one" {
    cp -r "${REFDB}" new-refdb
    local FORMAT FILE
    FORMAT="$(pf_var PF_REFDB_FORMAT_GTDB)"
    FILE="refdb-gtdb-format${FORMAT}.tar.gz"
    cp "${PF_FAKE_PACKAGES}/${FILE}" "${PF_FAKE_PACKAGES}/newer-${FILE}"
    sed "s/\t${FILE}\t/\tnewer-${FILE}\t/" "${REGISTRY}" > newer-registry.tsv
    : > "${PF_FAKE_LOG}"
    run env PATH="${PF_TESTS}/bin:${PATH}" PF_FAKE_LOG="${PF_FAKE_LOG}" bash "${PF_MAIN}" --refdb-dir new-refdb -o results setup \
        --refdb-registry newer-registry.tsv
    assert_success
    assert_output_contains "has a newer Zenodo package of GTDB: it replaces the installed one."
    assert_output_contains "NCBI reference data already installed"
    [[ "$(grep -c '^curl' "${PF_FAKE_LOG}")" -eq 1 ]]
    run grep -x "package=zenodo:1:newer-${FILE}" new-refdb/GTDB/COMPLETED-DOWNLOAD.txt
    assert_success
}

@test "an interrupted package download is resumed" {
    cp -r "${REFDB}" resume-refdb
    sed -i 's/^format=.*/format=1/' resume-refdb/NCBI/COMPLETED-DOWNLOAD.txt
    local FILE
    FILE="refdb-ncbi-format$(pf_var PF_REFDB_FORMAT_NCBI).tar.gz"
    mkdir -p resume-refdb/.zenodo-download
    head -c 1000 "${PF_FAKE_PACKAGES}/${FILE}" > "resume-refdb/.zenodo-download/${FILE}"
    : > "${PF_FAKE_LOG}"
    run env PATH="${PF_TESTS}/bin:${PATH}" PF_FAKE_LOG="${PF_FAKE_LOG}" bash "${PF_MAIN}" --refdb-dir resume-refdb -o results setup \
        --refdb-registry "${REGISTRY}"
    assert_success
    assert_output_contains "NCBI: resuming the download of ${FILE}"
    run grep -c '^curl .*-C - ' "${PF_FAKE_LOG}"
    assert_output_equals "1"
    assert_same_file "${PF_FIXTURE_REFDB}/NCBI/NULL-VALUES-NCBI.tsv" resume-refdb/NCBI/NULL-VALUES-NCBI.tsv
}

@test "a partial file that cannot be completed is downloaded again from the start" {
    cp -r "${REFDB}" stale-refdb
    sed -i 's/^format=.*/format=1/' stale-refdb/NCBI/COMPLETED-DOWNLOAD.txt
    local FILE
    FILE="refdb-ncbi-format$(pf_var PF_REFDB_FORMAT_NCBI).tar.gz"
    mkdir -p stale-refdb/.zenodo-download
    head -c 1000 /dev/urandom > "stale-refdb/.zenodo-download/${FILE}"
    : > "${PF_FAKE_LOG}"
    run env PATH="${PF_TESTS}/bin:${PATH}" PF_FAKE_LOG="${PF_FAKE_LOG}" bash "${PF_MAIN}" --refdb-dir stale-refdb -o results setup \
        --refdb-registry "${REGISTRY}"
    assert_success
    assert_output_contains "NCBI: the partial file ${FILE} could not be completed; downloading it again from the start."
    [[ "$(grep -c '^curl' "${PF_FAKE_LOG}")" -eq 2 ]]
    assert_same_file "${PF_FIXTURE_REFDB}/NCBI/NULL-VALUES-NCBI.tsv" stale-refdb/NCBI/NULL-VALUES-NCBI.tsv
}

@test "setup --from-source --yes over Zenodo databases is a full update that keeps the current databases until it ends" {
    local P
    for P in dataformat taxonkit jq gawk unzip; do
        command -v "${P}" >/dev/null 2>&1 || skip "${P} not installed"
    done
    cp -r "${REFDB}" full-refdb
    cp full-refdb/NCBI/COMPLETED-DOWNLOAD.txt ncbi-marker.txt
    : > "${PF_FAKE_LOG}"
    # (the fake curl and datasets serve nothing from the sources: the download of NCBI fails)
    run env PATH="${PF_TESTS}/bin:${PATH}" PF_FAKE_LOG="${PF_FAKE_LOG}" bash "${PF_MAIN}" --refdb-dir full-refdb -o results setup \
        --from-source --yes
    assert_failure
    assert_output_contains "is a full update: NCBI BACDIVE GTDB will be downloaded again"
    assert_output_contains "The full update was confirmed (--yes)."
    assert_output_contains "Installing the new NCBI database in the temporary folder"
    [[ -s "${PF_FAKE_LOG}" ]]
    assert_same_file ncbi-marker.txt full-refdb/NCBI/COMPLETED-DOWNLOAD.txt
    assert_file_exists full-refdb/GTDB/BACTERIA-GTDB-TAXONOMY/bac120_taxonomy_formatted.tsv
}

@test "an installed database of an older format is replaced by the new package" {
    cp -r "${REFDB}" old-refdb
    sed -i 's/^format=.*/format=1/' old-refdb/GTDB/COMPLETED-DOWNLOAD.txt
    : > "${PF_FAKE_LOG}"
    run env PATH="${PF_TESTS}/bin:${PATH}" PF_FAKE_LOG="${PF_FAKE_LOG}" bash "${PF_MAIN}" --refdb-dir old-refdb -o results setup \
        --refdb-registry "${REGISTRY}"
    assert_success
    assert_output_contains "the Zenodo package of the current format replaces them"
    [[ "$(grep -c '^curl' "${PF_FAKE_LOG}")" -eq 1 ]]
}

@test "a package with a wrong MD5 is refused and removed" {
    sed 's/\t[0-9a-f]\{32\}$/\t00000000000000000000000000000000/' "${REGISTRY}" > bad-registry.tsv
    run env PATH="${PF_TESTS}/bin:${PATH}" bash "${PF_MAIN}" --refdb-dir bad-refdb -o results setup --refdb-registry bad-registry.tsv
    assert_failure
    assert_output_contains "MD5 of refdb-ncbi-format"
    assert_file_not_exists bad-refdb/NCBI/COMPLETED-DOWNLOAD.txt
    assert_file_not_exists bad-refdb/.zenodo-download/refdb-ncbi-format3.tar.gz
}

@test "a registry without a package of the format the code reads says to use --from-source" {
    grep -v $'^PACKAGE\tGTDB' "${REGISTRY}" > partial-registry.tsv
    run env PATH="${PF_TESTS}/bin:${PATH}" bash "${PF_MAIN}" --refdb-dir partial-refdb -o results setup --refdb-registry partial-registry.tsv
    assert_failure
    assert_output_contains "Use setup --from-source"
}

@test "--ncbi-complete-metadata needs --from-source" {
    run bash "${PF_MAIN}" --refdb-dir refdb2 -o results setup --ncbi-complete-metadata
    assert_failure 1
    assert_output_contains "--ncbi-complete-metadata is not in the Zenodo packages: add --from-source."
}
