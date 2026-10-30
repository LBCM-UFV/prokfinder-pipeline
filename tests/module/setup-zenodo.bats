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
        # (a package has the formatted tables only: the taxdump and the normalization of the TaxIDs are made by setup)
        tar -czf "${PF_FAKE_PACKAGES}/${FILE}" -C "${PF_FIXTURE_REFDB}" \
            --exclude=TAXDUMP --exclude='*-taxid-status.tsv' --exclude=TAXID-NORMALIZATION-COMPLETED.txt \
            --exclude=taxid-unresolved.tsv "${DB}"
        printf 'PACKAGE\t%s\t%s\t%s\t%s\n' "${DB}" "${FORMAT}" "${FILE}" \
            "$(md5sum "${PF_FAKE_PACKAGES}/${FILE}" | cut -d' ' -f1)" >> "${REGISTRY}"
    done
    # NCBI taxdump served by the fake curl
    tar -czf "${PF_FAKE_PACKAGES}/taxdump.tar.gz" -C "${PF_FIXTURE_REFDB}/NCBI/TAXDUMP" names.dmp nodes.dmp merged.dmp delnodes.dmp
    export PF_FAKE_LOG="${BATS_FILE_TMPDIR}/calls.log"

    cd "${BATS_FILE_TMPDIR}" || return 1
    PATH="${PF_TESTS}/bin:${PATH}" bash "$(pf_main_with_registry "${REGISTRY}")" --refdb-dir refdb -o results setup \
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

@test "setup downloads the taxdump and normalizes the NCBI TaxIDs of the new tables" {
    run cat "${BATS_FILE_TMPDIR}/setup.log"
    assert_output_contains "-------- normalize-ncbi-taxids.sh --------"
    assert_output_contains "NCBI TaxID normalization completed successfully!"
    assert_file_exists "${REFDB}/NCBI/TAXID-NORMALIZATION-COMPLETED.txt"
    run grep -x 'taxdump_date=2026-10-01' "${REFDB}/NCBI/TAXID-NORMALIZATION-COMPLETED.txt"
    assert_success
    local DOMAIN SOURCE
    for DOMAIN in BACTERIA ARCHAEA; do
        for SOURCE in genbank refseq; do
            assert_same_file "${PF_FIXTURE_REFDB}/NCBI/${DOMAIN}-NCBI-METADATA/${SOURCE}-taxid-status.tsv" \
                "${REFDB}/NCBI/${DOMAIN}-NCBI-METADATA/${SOURCE}-taxid-status.tsv"
        done
    done
    assert_same_file "${PF_FIXTURE_REFDB}/BACDIVE/BACDIVE-FORMATTED-TSV/bacdive-taxid-status.tsv" \
        "${REFDB}/BACDIVE/BACDIVE-FORMATTED-TSV/bacdive-taxid-status.tsv"
    assert_file_exists "${REFDB}/NCBI/TAXDUMP/nodes.dmp"
}

@test "no temporary folder is left in the reference databases folder" {
    run bash -c "ls -A '${REFDB}' | grep -v '^.download.lock$' | grep -v '^.taxdump.lock$'"
    assert_output_equals "$(printf 'BACDIVE\nGTDB\nNCBI')"
    run bash -c "ls -A '${REFDB}/NCBI' | grep -c 'TAXDUMP\\.'"
    assert_output_equals "0"
}

@test "setup again downloads nothing and says that the databases are ready" {
    : > "${PF_FAKE_LOG}"
    run env PATH="${PF_TESTS}/bin:${PATH}" PF_FAKE_LOG="${PF_FAKE_LOG}" bash "$(pf_main_with_registry "${REGISTRY}")" --refdb-dir "${REFDB}" -o results setup
    assert_success
    assert_output_contains "NCBI reference data already installed"
    assert_output_contains "The reference databases are ready: NCBI TaxIDs normalized on"
    [[ "$(grep -c '^curl' "${PF_FAKE_LOG}" || true)" -eq 0 ]]
}

@test "setup --update-taxdump-file downloads only the taxdump and normalizes again" {
    cp -r "${REFDB}" update-refdb
    printf 'date=2020-01-01\ntaxdump_date=2020-01-01\n' > update-refdb/NCBI/TAXID-NORMALIZATION-COMPLETED.txt
    : > "${PF_FAKE_LOG}"
    run env PATH="${PF_TESTS}/bin:${PATH}" PF_FAKE_LOG="${PF_FAKE_LOG}" bash "$(pf_main_with_registry "${REGISTRY}")" --refdb-dir update-refdb -o results setup --update-taxdump-file
    assert_success
    assert_output_contains "Option --update-taxdump-file"
    assert_output_contains "NCBI TaxID normalization completed successfully!"
    [[ "$(grep -c '^curl' "${PF_FAKE_LOG}")" -eq 1 ]]
    run grep -x "date=$(date +%F)" update-refdb/NCBI/TAXID-NORMALIZATION-COMPLETED.txt
    assert_success
}

@test "setup without the checkpoint of the normalization downloads the taxdump and normalizes (tables are kept)" {
    cp -r "${REFDB}" nomarker-refdb
    rm nomarker-refdb/NCBI/TAXID-NORMALIZATION-COMPLETED.txt
    : > "${PF_FAKE_LOG}"
    run env PATH="${PF_TESTS}/bin:${PATH}" PF_FAKE_LOG="${PF_FAKE_LOG}" bash "$(pf_main_with_registry "${REGISTRY}")" --refdb-dir nomarker-refdb -o results setup
    assert_success
    assert_output_contains "NCBI reference data already installed"
    assert_output_contains "NCBI TaxID normalization completed successfully!"
    [[ "$(grep -c '^curl' "${PF_FAKE_LOG}")" -eq 1 ]]
    assert_file_exists nomarker-refdb/NCBI/TAXID-NORMALIZATION-COMPLETED.txt
}

@test "setup --from-zenodo with the packages up to date installs nothing" {
    : > "${PF_FAKE_LOG}"
    run env PATH="${PF_TESTS}/bin:${PATH}" PF_FAKE_LOG="${PF_FAKE_LOG}" bash "$(pf_main_with_registry "${REGISTRY}")" --refdb-dir "${REFDB}" -o results setup --from-zenodo
    assert_success
    assert_output_contains "Option --from-zenodo"
    [[ "$(grep -c '^curl' "${PF_FAKE_LOG}" || true)" -eq 0 ]]
    assert_file_exists "${REFDB}/NCBI/TAXID-NORMALIZATION-COMPLETED.txt"
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

@test "a newer package in the registry: setup only warns; setup --from-zenodo replaces the installed one" {
    cp -r "${REFDB}" new-refdb
    local FORMAT FILE
    FORMAT="$(pf_var PF_REFDB_FORMAT_GTDB)"
    FILE="refdb-gtdb-format${FORMAT}.tar.gz"
    cp "${PF_FAKE_PACKAGES}/${FILE}" "${PF_FAKE_PACKAGES}/newer-${FILE}"
    sed "s/\t${FILE}\t/\tnewer-${FILE}\t/" "${REGISTRY}" > newer-registry.tsv
    # plain setup: only a warning, nothing is downloaded
    : > "${PF_FAKE_LOG}"
    run env PATH="${PF_TESTS}/bin:${PATH}" PF_FAKE_LOG="${PF_FAKE_LOG}" bash "$(pf_main_with_registry newer-registry.tsv)" --refdb-dir new-refdb -o results setup
    assert_success
    assert_output_contains "has a newer Zenodo package of GTDB than the one installed; setup does not replace it"
    assert_output_contains "setup --from-zenodo"
    [[ "$(grep -c '^curl' "${PF_FAKE_LOG}" || true)" -eq 0 ]]
    run grep -x "package=zenodo:1:newer-${FILE}" new-refdb/GTDB/COMPLETED-DOWNLOAD.txt
    assert_failure
    # --from-zenodo: the package is replaced; GTDB has no NCBI TaxIDs, so the normalization stays valid
    : > "${PF_FAKE_LOG}"
    run env PATH="${PF_TESTS}/bin:${PATH}" PF_FAKE_LOG="${PF_FAKE_LOG}" bash "$(pf_main_with_registry newer-registry.tsv)" --refdb-dir new-refdb -o results setup --from-zenodo
    assert_success
    assert_output_contains "has a newer Zenodo package of GTDB: it replaces the installed one."
    assert_output_contains "NCBI reference data already installed"
    refute_output_contains "not normalized yet"
    [[ "$(grep -c '^curl' "${PF_FAKE_LOG}")" -eq 1 ]]
    run grep -x "package=zenodo:1:newer-${FILE}" new-refdb/GTDB/COMPLETED-DOWNLOAD.txt
    assert_success
    assert_file_exists new-refdb/NCBI/TAXID-NORMALIZATION-COMPLETED.txt
}

@test "a newer NCBI package installed by --from-zenodo invalidates the normalization: searches are refused until setup" {
    cp -r "${REFDB}" newncbi-refdb
    local FILE
    FILE="refdb-ncbi-format$(pf_var PF_REFDB_FORMAT_NCBI).tar.gz"
    cp "${PF_FAKE_PACKAGES}/${FILE}" "${PF_FAKE_PACKAGES}/newer-${FILE}"
    sed "s/\t${FILE}\t/\tnewer-${FILE}\t/" "${REGISTRY}" > newer-ncbi-registry.tsv
    : > "${PF_FAKE_LOG}"
    run env PATH="${PF_TESTS}/bin:${PATH}" PF_FAKE_LOG="${PF_FAKE_LOG}" bash "$(pf_main_with_registry newer-ncbi-registry.tsv)" --refdb-dir newncbi-refdb -o results setup --from-zenodo
    assert_success
    assert_output_contains "has a newer Zenodo package of NCBI: it replaces the installed one."
    assert_output_contains "The NCBI TaxIDs of the new tables are not normalized yet"
    [[ "$(grep -c '^curl' "${PF_FAKE_LOG}")" -eq 1 ]]
    assert_file_not_exists newncbi-refdb/NCBI/TAXID-NORMALIZATION-COMPLETED.txt
    # the search is refused until setup normalizes; setup keeps the taxdump it already had and downloads it again
    run bash "${PF_MAIN}" --refdb-dir newncbi-refdb -o refused search-genomes -G 40:65
    assert_failure
    assert_output_contains "were not normalized"
    run env PATH="${PF_TESTS}/bin:${PATH}" PF_FAKE_LOG="${PF_FAKE_LOG}" bash "$(pf_main_with_registry newer-ncbi-registry.tsv)" --refdb-dir newncbi-refdb -o results setup
    assert_success
    assert_file_exists newncbi-refdb/NCBI/TAXID-NORMALIZATION-COMPLETED.txt
    run bash "${PF_MAIN}" --refdb-dir newncbi-refdb -o ok search-genomes -G 40:65
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
    run env PATH="${PF_TESTS}/bin:${PATH}" PF_FAKE_LOG="${PF_FAKE_LOG}" bash "$(pf_main_with_registry "${REGISTRY}")" --refdb-dir resume-refdb -o results setup
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
    run env PATH="${PF_TESTS}/bin:${PATH}" PF_FAKE_LOG="${PF_FAKE_LOG}" bash "$(pf_main_with_registry "${REGISTRY}")" --refdb-dir stale-refdb -o results setup
    assert_success
    assert_output_contains "NCBI: the partial file ${FILE} could not be completed; downloading it again from the start."
    # (the package twice, then the taxdump)
    [[ "$(grep -c '^curl' "${PF_FAKE_LOG}")" -eq 3 ]]
    assert_same_file "${PF_FIXTURE_REFDB}/NCBI/NULL-VALUES-NCBI.tsv" stale-refdb/NCBI/NULL-VALUES-NCBI.tsv
}

@test "setup --from-source (confirmed) over Zenodo databases is a full update that keeps the current databases until it ends" {
    local P
    for P in dataformat jq gawk unzip; do
        command -v "${P}" >/dev/null 2>&1 || skip "${P} not installed"
    done
    cp -r "${REFDB}" full-refdb
    cp full-refdb/NCBI/COMPLETED-DOWNLOAD.txt ncbi-marker.txt
    : > "${PF_FAKE_LOG}"
    # (the fake curl and datasets serve nothing from the sources: the download of NCBI fails)
    # (inside a PBS job there is no terminal: run-on-cluster asked before submitting it)
    run env PBS_JOBID=1.fake PATH="${PF_TESTS}/bin:${PATH}" PF_FAKE_LOG="${PF_FAKE_LOG}" bash "${PF_MAIN}" --refdb-dir full-refdb -o results setup \
        --from-source
    assert_failure
    assert_output_contains "is a full update: NCBI BACDIVE GTDB will be downloaded again"
    assert_output_contains "The full update was confirmed."
    assert_output_contains "Installing the new NCBI database in the temporary folder"
    [[ -s "${PF_FAKE_LOG}" ]]
    assert_same_file ncbi-marker.txt full-refdb/NCBI/COMPLETED-DOWNLOAD.txt
    assert_file_exists full-refdb/GTDB/BACTERIA-GTDB-TAXONOMY/bac120_taxonomy_formatted.tsv
    # (the tables are going to change: the normalization of their TaxIDs is not valid any more)
    assert_file_not_exists full-refdb/NCBI/TAXID-NORMALIZATION-COMPLETED.txt
}

@test "an installed database of an older format is replaced by the new package" {
    cp -r "${REFDB}" old-refdb
    sed -i 's/^format=.*/format=1/' old-refdb/GTDB/COMPLETED-DOWNLOAD.txt
    : > "${PF_FAKE_LOG}"
    run env PATH="${PF_TESTS}/bin:${PATH}" PF_FAKE_LOG="${PF_FAKE_LOG}" bash "$(pf_main_with_registry "${REGISTRY}")" --refdb-dir old-refdb -o results setup
    assert_success
    assert_output_contains "the Zenodo package of the current format replaces them"
    # (only the package: the GTDB tables have no NCBI TaxIDs, so the normalization is kept and no taxdump is downloaded)
    [[ "$(grep -c '^curl' "${PF_FAKE_LOG}")" -eq 1 ]]
}

@test "a package with a wrong MD5 is refused and removed" {
    sed 's/\t[0-9a-f]\{32\}$/\t00000000000000000000000000000000/' "${REGISTRY}" > bad-registry.tsv
    run env PATH="${PF_TESTS}/bin:${PATH}" bash "$(pf_main_with_registry bad-registry.tsv)" --refdb-dir bad-refdb -o results setup
    assert_failure
    assert_output_contains "MD5 of refdb-ncbi-format"
    assert_file_not_exists bad-refdb/NCBI/COMPLETED-DOWNLOAD.txt
    assert_file_not_exists bad-refdb/.zenodo-download/refdb-ncbi-format3.tar.gz
}

@test "a registry without a package of the format the code reads says to use --from-source" {
    grep -v $'^PACKAGE\tGTDB' "${REGISTRY}" > partial-registry.tsv
    run env PATH="${PF_TESTS}/bin:${PATH}" bash "$(pf_main_with_registry partial-registry.tsv)" --refdb-dir partial-refdb -o results setup
    assert_failure
    assert_output_contains "Use setup --from-source"
}

@test "setup has no --yes, --ncbi-complete-metadata or --refdb-registry" {
    local OPTION
    for OPTION in --yes --ncbi-complete-metadata; do
        run bash "${PF_MAIN}" --refdb-dir refdb2 -o results setup "${OPTION}"
        assert_failure 1
        assert_output_contains "Unknown option: '${OPTION}'."
    done
    run bash "${PF_MAIN}" --refdb-dir refdb2 -o results setup --refdb-registry x.tsv
    assert_failure 1
    assert_output_contains "Unknown option: '--refdb-registry'."
}
