#!/usr/bin/env bats
#
# normalize-ncbi-taxids.sh on a small taxonomy written here: CURRENT, MERGED (also through a chain), DELETED and INVALID
# TaxIDs, the rescue by name (ends trimmed, case ignored, a "\r" inside the name, a homonym outside Bacteria/Archaea,
# two homonyms inside = AMBIGUOUS, an unknown name = UNRESOLVED), SPECIES_TAXID and RANK

setup_file() {
    load ../helpers/common
    export HOME="${BATS_FILE_TMPDIR}/home" TMPDIR="${BATS_FILE_TMPDIR}/tmp" NO_COLOR=1 PF_COLOR=0
    mkdir -p "${HOME}" "${TMPDIR}"
    local REFDB="${BATS_FILE_TMPDIR}/refdb" TAXDUMP="${BATS_FILE_TMPDIR}/refdb/NCBI/TAXDUMP" META
    mkdir -p "${TAXDUMP}"

    # nodes.dmp: <taxid> | <parent> | <rank> |
    # 2 Bacteria, 2157 Archaea, 2759 Eukaryota; genus 10 > species 11 > strain 12; species 13 and 14 (homonyms) and
    # genus 20 > species 21 in Archaea; species 40 in Eukaryota
    local ID PARENT RANK
    while read -r ID PARENT RANK; do
        printf '%s\t|\t%s\t|\t%s\t|\t\t|\n' "${ID}" "${PARENT}" "${RANK}"
    done > "${TAXDUMP}/nodes.dmp" << 'EOF'
1 1 no_rank
131567 1 no_rank
2 131567 domain
2157 131567 domain
2759 131567 domain
10 2 genus
11 10 species
12 11 strain
13 10 species
14 10 species
20 2157 genus
21 20 species
40 2759 species
EOF
    sed -i 's/no_rank/no rank/' "${TAXDUMP}/nodes.dmp"
    # names.dmp: <taxid> | <name> | <unique name> | <class> | (the order of the lines decides the first TaxID)
    local NAME
    while IFS='|' read -r ID NAME; do
        printf '%s\t|\t%s\t|\t\t|\tscientific name\t|\n' "${ID}" "${NAME}"
    done > "${TAXDUMP}/names.dmp" << 'EOF'
2|Bacteria
2157|Archaea
10|Genus G
11|Alpha beta
12|Alpha beta ST1
13|Epsilon zeta
14|Epsilon zeta
21|Gamma delta
40|Alpha beta
EOF
    # merged.dmp: <old> | <new> |  (98 -> 97 -> 11: a chain)    delnodes.dmp: <taxid> |
    printf '99\t|\t12\t|\n98\t|\t97\t|\n97\t|\t11\t|\n' > "${TAXDUMP}/merged.dmp"
    printf '77\t|\n' > "${TAXDUMP}/delnodes.dmp"

    # NCBI table (BACTERIA genbank); the other three tables only have the header
    META="${REFDB}/NCBI/BACTERIA-NCBI-METADATA"
    mkdir -p "${META}" "${REFDB}/NCBI/ARCHAEA-NCBI-METADATA" "${REFDB}/BACDIVE/BACDIVE-FORMATTED-TSV"
    local HEADER='ASSEMBLY_ACCESSION\tORGANISM_NAME\tORGANISM_TAXONOMIC_ID'
    {
        printf "${HEADER}\n"
        printf 'GCA_1.1\tAlpha beta ST1\t12\n'
        printf 'GCA_2.1\tx\t99\n'
        printf 'GCA_3.1\tx\t98\n'
        printf 'GCA_4.1\tGamma delta\t77\n'
        printf 'GCA_5.1\t  gamma DELTA \r\t5555\n'
        printf 'GCA_6.1\tAlpha beta\t77\n'
        printf 'GCA_7.1\tEpsilon zeta\t5555\n'
        printf 'GCA_8.1\tNo such name\t5555\n'
        printf 'GCA_9.1\tAlpha beta\tNULL\n'
        printf 'GCA_10.1\tGenus G\t10\n'
    } > "${META}/genbank-metadata.tsv"
    printf "${HEADER}\n" > "${META}/refseq-metadata.tsv"
    printf "${HEADER}\n" > "${REFDB}/NCBI/ARCHAEA-NCBI-METADATA/genbank-metadata.tsv"
    printf "${HEADER}\n" > "${REFDB}/NCBI/ARCHAEA-NCBI-METADATA/refseq-metadata.tsv"
    # BacDive table (one row per NCBI TaxID)
    printf 'ncbi_tax_id\tbacdive_strains\n11\t3\n99\t1\n77\t1\n5555\t1\n' \
        > "${REFDB}/BACDIVE/BACDIVE-FORMATTED-TSV/BACDIVE_CONCATENATED_STRAINS_FOR_SPECIES.tsv"

    cd "${BATS_FILE_TMPDIR}" || return 1
    bash "${PF_ROOT}/modules/normalize-ncbi-taxids.sh" -o "${REFDB}" --skip-download > normalize.log 2>&1
    echo "$?" > normalize.status
}

setup() {
    load ../helpers/common
    REFDB="${BATS_FILE_TMPDIR}/refdb"
    STATUS="${REFDB}/NCBI/BACTERIA-NCBI-METADATA/genbank-taxid-status.tsv"
}

# Usage: status_of <accession> -> TAXID_STATUS, UPDATED_TAXID, SPECIES_TAXID and RANK, separated by spaces
status_of() {
    awk -F'\t' -v a="$1" '$1 == a { print $3, $4, $5, $6 }' "${STATUS}"
}

@test "the normalization finishes and writes the checkpoint last" {
    [[ "$(cat "${BATS_FILE_TMPDIR}/normalize.status")" -eq 0 ]] || { cat "${BATS_FILE_TMPDIR}/normalize.log" >&2; return 1; }
    assert_file_exists "${REFDB}/NCBI/TAXID-NORMALIZATION-COMPLETED.txt"
    run grep -c '^date=' "${REFDB}/NCBI/TAXID-NORMALIZATION-COMPLETED.txt"
    assert_output_equals "1"
    run grep -x 'status.BACTERIA-genbank.RESCUED=4' "${REFDB}/NCBI/TAXID-NORMALIZATION-COMPLETED.txt"
    assert_success
}

@test "CURRENT: the TaxID is kept; SPECIES_TAXID and RANK come from the taxonomy" {
    run status_of GCA_1.1
    assert_output_equals "CURRENT 12 11 strain"
}

@test "CURRENT above species: SPECIES_TAXID is NULL" {
    run status_of GCA_10.1
    assert_output_equals "CURRENT 10 NULL genus"
}

@test "MERGED: the TaxID it was merged into, also through a chain of merges" {
    run status_of GCA_2.1
    assert_output_equals "MERGED 12 11 strain"
    run status_of GCA_3.1
    assert_output_equals "MERGED 11 11 species"
}

@test "DELETED and INVALID are rescued by the name: ends trimmed, case ignored, a \\r inside the name" {
    run status_of GCA_4.1
    assert_output_equals "RESCUED 21 21 species"
    run status_of GCA_5.1
    assert_output_equals "RESCUED 21 21 species"
}

@test "rescue: a homonym outside Bacteria and Archaea is ignored; an invalid TaxID NULL is rescued too" {
    run status_of GCA_6.1
    assert_output_equals "RESCUED 11 11 species"
    run status_of GCA_9.1
    assert_output_equals "RESCUED 11 11 species"
}

@test "rescue: two homonyms in Bacteria = AMBIGUOUS, with the first TaxID" {
    run status_of GCA_7.1
    assert_output_equals "AMBIGUOUS 13 13 species"
}

@test "rescue: an unknown name = UNRESOLVED, no TaxID, and the genome stays in the table" {
    run status_of GCA_8.1
    assert_output_equals "UNRESOLVED NULL NULL NULL"
    run awk 'END { print NR }' "${STATUS}"
    assert_output_equals "11"
}

@test "the report lists what is not CURRENT or MERGED" {
    run awk -F'\t' 'NR > 1 { print $2, $5 }' "${REFDB}/NCBI/taxid-unresolved.tsv"
    assert_output_contains "GCA_8.1 UNRESOLVED"
    assert_output_contains "GCA_7.1 AMBIGUOUS"
    refute_output_contains "GCA_1.1"
    refute_output_contains "GCA_2.1"
}

@test "BacDive: no names to rescue, so DELETED and INVALID stay as they are; the rank is the one of the current TaxID" {
    run awk -F'\t' 'NR > 1 { print $1, $2, $3, $4, $5 }' "${REFDB}/BACDIVE/BACDIVE-FORMATTED-TSV/bacdive-taxid-status.tsv"
    assert_output_contains "11 CURRENT 11 11 species"
    assert_output_contains "99 MERGED 12 11 strain"
    assert_output_contains "77 DELETED NULL NULL NULL"
    assert_output_contains "5555 INVALID NULL NULL NULL"
}

@test "TAXDUMP_DATE is the date of the taxdump in every row" {
    run awk -F'\t' 'NR > 1 { print $7 }' "${STATUS}"
    [[ "$(printf '%s\n' "${output}" | sort -u | wc -l)" -eq 1 ]]
}

@test "--skip-download without the taxdump is an error that says what to run" {
    mkdir -p empty/NCBI
    run bash "${PF_ROOT}/modules/normalize-ncbi-taxids.sh" -o empty --skip-download
    assert_failure
    assert_output_contains "Run: setup --update-taxdump-file"
}
