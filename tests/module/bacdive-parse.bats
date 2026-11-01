#!/usr/bin/env bats
#
# download-reference-db-bacdive.sh on one strain written here (--skip-download): the species name, a record without @ref
# as a reference of its own, the salinity in M, mM and g/L converted to %, *_range split in *_range_min and *_range_max,
# one column per class (shares) and the biosafety levels 1 to 4

setup_file() {
    load ../helpers/common
    export HOME="${BATS_FILE_TMPDIR}/home" TMPDIR="${BATS_FILE_TMPDIR}/tmp" NO_COLOR=1 PF_COLOR=0
    mkdir -p "${HOME}" "${TMPDIR}"
    local DIR="${BATS_FILE_TMPDIR}/bacdive"
    mkdir -p "${DIR}/BACDIVE-DOWNLOAD-BRUTE"
    # Three records of "cell morphology": one with @ref 100 and two without (they are the references noref-1 and noref-2).
    # Salinity: 1 M (optimum, ref 100), 20 g/L and 100 mM (growth)
    cat > "${DIR}/BACDIVE-DOWNLOAD-BRUTE/batch_00000.jsonl" << 'EOF'
{"id":1,"data":{"General":{"NCBI tax id":{"NCBI tax id":274,"Matching level":"species"}},"Name and taxonomic classification":{"species":"Thermus thermophilus"},"Morphology":{"cell morphology":[{"@ref":100,"gram stain":"negative","cell shape":"rod"},{"gram stain":"negative","cell shape":"rod"},{"cell shape":"coccus"}]},"Culture and growth conditions":{"culture temp":[{"@ref":100,"growth":"positive","type":"minimum","temperature":"45"},{"@ref":100,"growth":"positive","type":"maximum","temperature":"80"},{"@ref":100,"growth":"positive","type":"optimum","temperature":"70"}]},"Physiology and metabolism":{"halophily":[{"@ref":100,"salt":"NaCl","growth":"positive","tested relation":"optimum","concentration":"1 M"},{"@ref":101,"salt":"NaCl","growth":"positive","tested relation":"growth","concentration":"20 g/L"},{"@ref":102,"salt":"NaCl","growth":"positive","tested relation":"growth","concentration":"100 mM"}]},"Interaction and safety":{"risk assessment":[{"@ref":9,"biosafety level":"1"},{"@ref":10,"biosafety level":"0"}]}}}
{"id":2,"data":{"General":{"NCBI tax id":[{"NCBI tax id":1299,"Matching level":"species"},{"NCBI tax id":243230,"Matching level":"strain"}]}}}
EOF
    cd "${BATS_FILE_TMPDIR}" || return 1
    bash "${PF_ROOT}/modules/download-reference-db-bacdive.sh" -o "${DIR}" --skip-download > bacdive.log 2>&1
    echo "$?" > bacdive.status
}

setup() {
    load ../helpers/common
    TABLES="${BATS_FILE_TMPDIR}/bacdive/BACDIVE-FORMATTED-TSV"
}

# Usage: cell <table> <bacdive_id> <column>
cell() {
    awk -F'\t' -v id="$2" -v c="$3" 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == c) k = i; next } $1 == id { print $k }' "$1"
}

@test "the module finishes, the checkpoint has the table format, and the table of the species is not written by it" {
    [[ "$(cat "${BATS_FILE_TMPDIR}/bacdive.status")" -eq 0 ]] || { cat "${BATS_FILE_TMPDIR}/bacdive.log" >&2; return 1; }
    assert_file_exists "${TABLES}/BACDIVE_CONCATENATED_REFERENCES_FOR_STRAIN.tsv"
    assert_file_not_exists "${TABLES}/BACDIVE_CONCATENATED_STRAINS_FOR_SPECIES.tsv"
    run grep -x "format=$(pf_var PF_REFDB_FORMAT_BACDIVE)" "${BATS_FILE_TMPDIR}/bacdive/COMPLETED-DOWNLOAD.txt"
    assert_success
}

@test "the species name is a column of the tables; a strain without it has NULL" {
    run cell "${TABLES}/BACDIVE_DATA_FORMATTED.tsv" 1 species
    assert_output_equals "Thermus thermophilus"
    run cell "${TABLES}/BACDIVE_DATA_FORMATTED.tsv" 2 species
    assert_output_equals "NULL"
    run cell "${TABLES}/BACDIVE_CONCATENATED_REFERENCES_FOR_STRAIN.tsv" 1 species
    assert_output_equals "Thermus thermophilus"
    run cell "${TABLES}/BACDIVE_DATA_FORMATTED.tsv" 2 ncbi_tax_id
    assert_output_equals "1299;243230"
}

@test "a record without @ref is a reference of its own: rod, rod and coccus give 2/3 and 1/3" {
    run cell "${TABLES}/BACDIVE_CONCATENATED_REFERENCES_FOR_STRAIN.tsv" 1 cell_shape_rod
    assert_output_equals "0.667"
    run cell "${TABLES}/BACDIVE_CONCATENATED_REFERENCES_FOR_STRAIN.tsv" 1 cell_shape_coccus
    assert_output_equals "0.333"
    run cell "${TABLES}/BACDIVE_CONCATENATED_REFERENCES_FOR_STRAIN.tsv" 1 cell_shape_ovoid
    assert_output_equals "0"
}

@test "the log says how many records have no @ref" {
    run grep "Records without @ref" "${BATS_FILE_TMPDIR}/bacdive.log"
    assert_success
    assert_output_contains ": 2"
}

@test "the class columns of a trait with no data are NULL in every class, and a trait with data sums to 1" {
    run cell "${TABLES}/BACDIVE_CONCATENATED_REFERENCES_FOR_STRAIN.tsv" 1 gram_stain_negative
    assert_output_equals "1"
    run cell "${TABLES}/BACDIVE_CONCATENATED_REFERENCES_FOR_STRAIN.tsv" 1 gram_stain_positive
    assert_output_equals "0"
    run cell "${TABLES}/BACDIVE_CONCATENATED_REFERENCES_FOR_STRAIN.tsv" 1 motility_yes
    assert_output_equals "NULL"
    run cell "${TABLES}/BACDIVE_CONCATENATED_REFERENCES_FOR_STRAIN.tsv" 1 motility_no
    assert_output_equals "NULL"
}

@test "*_range is split in *_range_min and *_range_max, and there is no *_range column" {
    run cell "${TABLES}/BACDIVE_CONCATENATED_REFERENCES_FOR_STRAIN.tsv" 1 temperature_range_min
    assert_output_equals "45"
    run cell "${TABLES}/BACDIVE_CONCATENATED_REFERENCES_FOR_STRAIN.tsv" 1 temperature_range_max
    assert_output_equals "80"
    run awk -F'\t' 'NR == 1 { for (i = 1; i <= NF; i++) if ($i ~ /_range$/) print $i }' "${TABLES}/BACDIVE_CONCATENATED_REFERENCES_FOR_STRAIN.tsv"
    assert_output_equals ""
}

@test "salinity: molar, millimolar and g/L are converted to % (NaCl: 1 M = 5.844 %)" {
    run cell "${TABLES}/BACDIVE_DATA_FORMATTED.tsv" 1 halophily_opt
    assert_output_equals "5.844"
    run cell "${TABLES}/BACDIVE_DATA_FORMATTED.tsv" 1 halophily_preference
    assert_output_equals "0.584;2;5.844"
}

@test "biosafety level: only 1 to 4" {
    run cell "${TABLES}/BACDIVE_CONCATENATED_REFERENCES_FOR_STRAIN.tsv" 1 biosafety_level_1
    assert_output_equals "1"
    run cell "${TABLES}/BACDIVE_CONCATENATED_REFERENCES_FOR_STRAIN.tsv" 1 biosafety_level_2
    assert_output_equals "0"
}
