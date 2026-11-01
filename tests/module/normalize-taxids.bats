#!/usr/bin/env bats
#
# normalize-ncbi-taxids.sh on a small taxonomy written here: CURRENT, MERGED (also through a chain), DELETED and INVALID
# TaxIDs, the rescue by name (ends trimmed, case ignored, a "\r" inside the name, a homonym outside Bacteria/Archaea,
# two homonyms inside = AMBIGUOUS, an unknown name = UNRESOLVED), the TaxIDs below species collapsed to their species
# (RANK, UPDATED_RANK, UPDATED_ORGANISM_NAME), and the BacDive strains merged by the current species

setup_file() {
    load ../helpers/common
    export HOME="${BATS_FILE_TMPDIR}/home" TMPDIR="${BATS_FILE_TMPDIR}/tmp" NO_COLOR=1 PF_COLOR=0
    mkdir -p "${HOME}" "${TMPDIR}"
    local REFDB="${BATS_FILE_TMPDIR}/refdb" TAXDUMP="${BATS_FILE_TMPDIR}/refdb/NCBI/TAXDUMP" META
    mkdir -p "${TAXDUMP}"

    # nodes.dmp: <taxid> | <parent> | <rank> |
    # 2 Bacteria, 2157 Archaea, 2759 Eukaryota; genus 10 > species 11 > strain 12, subspecies 15 > no rank 16;
    # species 13 and 14 (homonyms) and genus 20 > species 21 in Archaea; species 40 in Eukaryota
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
15 11 subspecies
16 15 no_rank
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
        printf 'GCA_11.1\tx\t15\n'
        printf 'GCA_12.1\tx\t16\n'
    } > "${META}/genbank-metadata.tsv"
    printf "${HEADER}\n" > "${META}/refseq-metadata.tsv"
    printf "${HEADER}\n" > "${REFDB}/NCBI/ARCHAEA-NCBI-METADATA/genbank-metadata.tsv"
    printf "${HEADER}\n" > "${REFDB}/NCBI/ARCHAEA-NCBI-METADATA/refseq-metadata.tsv"

    # BacDive strain table (references merged): the columns of the module (one per class of each trait divided in classes)
    local COLUMNS
    COLUMNS="$(bash -c 'source "$1/lib/common.sh"; for t in "${PF_BACDIVE_CLASS_TRAITS[@]}"; do for c in $(pf_bacdive_classes "$t"); do printf "%s_%s\n" "$t" "$c"; done; done' _ "${PF_ROOT}")"
    printf '%s\n' "bacdive_id" "ncbi_tax_id" "species" "temperature_opt" "temperature_range_min" "temperature_range_max" ${COLUMNS} \
        | paste -sd '\t' > "${BATS_FILE_TMPDIR}/strain-header.tsv"
    # S1 40 C, range 30-50, Gram positive;  S2 has the TaxID of the strain and of the species (counted once), 60 C, range
    # 20-35, no Gram; S3 has a merged TaxID, no temperature, Gram positive; S4 has a deleted TaxID and the name of a
    # species of Archaea (rescued); S5 an invalid TaxID and no name; S6 a TaxID of rank genus (not a species)
    {
        cat "${BATS_FILE_TMPDIR}/strain-header.tsv"
        strain_row 1 11 "Alpha beta" 40 30 50 1 0
        strain_row 2 "12;11" "Alpha beta ST1" 60 20 35 NULL NULL
        strain_row 3 99 "Alpha beta" NULL NULL NULL 1 0
        strain_row 4 77 "Gamma delta" 80 NULL NULL NULL NULL
        strain_row 5 5555 NULL 70 NULL NULL NULL NULL
        strain_row 6 10 "Genus G" 50 NULL NULL NULL NULL
    } > "${REFDB}/BACDIVE/BACDIVE-FORMATTED-TSV/BACDIVE_CONCATENATED_REFERENCES_FOR_STRAIN.tsv"

    cd "${BATS_FILE_TMPDIR}" || return 1
    bash "${PF_ROOT}/modules/normalize-ncbi-taxids.sh" -o "${REFDB}" --skip-download > normalize.log 2>&1
    echo "$?" > normalize.status
}

# Usage: strain_row <id> <ncbi_tax_id> <species> <temperature_opt> <range_min> <range_max> <gram_positive> <gram_negative>
# (the other columns are NULL; uses the header written in setup_file)
strain_row() {
    awk -F'\t' -v OFS='\t' -v v="$1|$2|$3|$4|$5|$6|$7|$8" '
        BEGIN { split(v, a, "|") }
        NR == 1 {
            for (i = 1; i <= NF; i++) {
                x = "NULL"
                if (i <= 6) x = a[i]
                else if ($i == "gram_stain_positive") x = a[7]
                else if ($i == "gram_stain_negative") x = a[8]
                out = out (i > 1 ? OFS : "") x
            }
            print out
        }' "${BATS_FILE_TMPDIR}/strain-header.tsv"
}

setup() {
    load ../helpers/common
    REFDB="${BATS_FILE_TMPDIR}/refdb"
    STATUS="${REFDB}/NCBI/BACTERIA-NCBI-METADATA/genbank-taxid-status.tsv"
    BACDIVE_DIR="${REFDB}/BACDIVE/BACDIVE-FORMATTED-TSV"
}

# Usage: status_of <accession> -> TAXID_STATUS, UPDATED_TAXID, RANK, UPDATED_RANK and UPDATED_ORGANISM_NAME, joined by "|"
status_of() {
    awk -F'\t' -v OFS='|' -v a="$1" '$1 == a { print $3, $4, $5, $6, $7 }' "${STATUS}"
}

# Usage: species_value <ncbi_tax_id> <column> -> the value of the species table of BacDive
species_value() {
    awk -F'\t' -v t="$1" -v c="$2" 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == c) k = i; next } $1 == t { print $k }' \
        "${BACDIVE_DIR}/BACDIVE_CONCATENATED_STRAINS_FOR_SPECIES.tsv"
}

@test "the normalization finishes and writes the checkpoint last" {
    [[ "$(cat "${BATS_FILE_TMPDIR}/normalize.status")" -eq 0 ]] || { cat "${BATS_FILE_TMPDIR}/normalize.log" >&2; return 1; }
    assert_file_exists "${REFDB}/NCBI/TAXID-NORMALIZATION-COMPLETED.txt"
    run grep -c '^date=' "${REFDB}/NCBI/TAXID-NORMALIZATION-COMPLETED.txt"
    assert_output_equals "1"
    run grep -x 'status.BACTERIA-genbank.RESCUED=4' "${REFDB}/NCBI/TAXID-NORMALIZATION-COMPLETED.txt"
    assert_success
}

@test "the status tables have TAXID (the original), RANK, UPDATED_RANK and UPDATED_ORGANISM_NAME, and no SPECIES_TAXID" {
    run awk -F'\t' 'NR == 1 { print; exit }' "${STATUS}"
    assert_output_equals "$(printf 'ASSEMBLY_ACCESSION\tTAXID\tTAXID_STATUS\tUPDATED_TAXID\tRANK\tUPDATED_RANK\tUPDATED_ORGANISM_NAME\tTAXDUMP_DATE')"
    run awk -F'\t' 'NR == 1 { print; exit }' "${BACDIVE_DIR}/bacdive-taxid-status.tsv"
    assert_output_equals "$(printf 'ncbi_tax_id\tTAXID_STATUS\tUPDATED_TAXID\tRANK\tUPDATED_RANK\tUPDATED_ORGANISM_NAME\tTAXDUMP_DATE')"
    run awk -F'\t' '$1 == "GCA_1.1" { print $2 }' "${STATUS}"
    assert_output_equals "12"
}

@test "a strain below species becomes its species: RANK is the original rank, UPDATED_RANK is species" {
    run status_of GCA_1.1
    assert_output_equals "CURRENT|11|strain|species|Alpha beta"
}

@test "a subspecies and a no rank below a species also become the species" {
    run status_of GCA_11.1
    assert_output_equals "CURRENT|11|subspecies|species|Alpha beta"
    run status_of GCA_12.1
    assert_output_equals "CURRENT|11|no rank|species|Alpha beta"
}

@test "CURRENT above species: the TaxID, its rank and its name are kept" {
    run status_of GCA_10.1
    assert_output_equals "CURRENT|10|genus|genus|Genus G"
}

@test "MERGED: the TaxID it was merged into (also through a chain), with the rank of that TaxID" {
    run status_of GCA_2.1
    assert_output_equals "MERGED|11|strain|species|Alpha beta"
    run status_of GCA_3.1
    assert_output_equals "MERGED|11|species|species|Alpha beta"
}

@test "DELETED and INVALID are rescued by the name: ends trimmed, case ignored, a \\r inside the name; RANK is NULL" {
    run status_of GCA_4.1
    assert_output_equals "RESCUED|21|NULL|species|Gamma delta"
    run status_of GCA_5.1
    assert_output_equals "RESCUED|21|NULL|species|Gamma delta"
}

@test "rescue: a homonym outside Bacteria and Archaea is ignored; an invalid TaxID NULL is rescued too" {
    run status_of GCA_6.1
    assert_output_equals "RESCUED|11|NULL|species|Alpha beta"
    run status_of GCA_9.1
    assert_output_equals "RESCUED|11|NULL|species|Alpha beta"
}

@test "rescue: two homonyms in Bacteria = AMBIGUOUS, with the first TaxID" {
    run status_of GCA_7.1
    assert_output_equals "AMBIGUOUS|13|NULL|species|Epsilon zeta"
}

@test "rescue: an unknown name = UNRESOLVED, no TaxID, and the genome stays in the table" {
    run status_of GCA_8.1
    assert_output_equals "UNRESOLVED|NULL|NULL|NULL|NULL"
    run awk 'END { print NR }' "${STATUS}"
    assert_output_equals "13"
}

@test "the report lists what is not CURRENT or MERGED" {
    run awk -F'\t' 'NR > 1 { print $2, $5 }' "${REFDB}/NCBI/taxid-unresolved.tsv"
    assert_output_contains "GCA_8.1 UNRESOLVED"
    assert_output_contains "GCA_7.1 AMBIGUOUS"
    refute_output_contains "GCA_1.1"
    refute_output_contains "GCA_2.1"
}

@test "the checkpoint counts the TaxIDs collapsed to their species by the original rank" {
    run grep -x 'collapsed.BACTERIA-genbank.strain=2' "${REFDB}/NCBI/TAXID-NORMALIZATION-COMPLETED.txt"
    assert_success
    run grep -x 'collapsed.BACTERIA-genbank.subspecies=1' "${REFDB}/NCBI/TAXID-NORMALIZATION-COMPLETED.txt"
    assert_success
    run grep -x 'collapsed.BACTERIA-genbank.no_rank=1' "${REFDB}/NCBI/TAXID-NORMALIZATION-COMPLETED.txt"
    assert_success
}

@test "BacDive: the DELETED TaxID is rescued by the species name of the strain; the rank is the one of the original TaxID" {
    run awk -F'\t' -v OFS='|' 'NR > 1 { print $1, $2, $3, $4, $5, $6 }' "${BACDIVE_DIR}/bacdive-taxid-status.tsv"
    assert_output_contains "11|CURRENT|11|species|species|Alpha beta"
    assert_output_contains "12|CURRENT|11|strain|species|Alpha beta"
    assert_output_contains "99|MERGED|11|strain|species|Alpha beta"
    assert_output_contains "77|RESCUED|21|NULL|species|Gamma delta"
    assert_output_contains "5555|UNRESOLVED|NULL|NULL|NULL|NULL"
}

@test "BacDive species table: strains merged by the current species (a strain counts once, strains of merged TaxIDs join)" {
    run species_value 11 bacdive_strains
    assert_output_equals "3"
    run species_value 11 species
    assert_output_equals "Alpha beta"
    # mean of the strains that have a value (40 and 60; the third has none)
    run species_value 11 temperature_opt
    assert_output_equals "50"
    run species_value 11 temperature_range_min
    assert_output_equals "20"
    run species_value 11 temperature_range_max
    assert_output_equals "50"
    # shares of the strains that have data for the trait (two of three)
    run species_value 11 gram_stain_positive
    assert_output_equals "1"
    run species_value 11 gram_stain_negative
    assert_output_equals "0"
    # no data at all for the trait: NULL in every class column
    run species_value 11 cell_shape_rod
    assert_output_equals "NULL"
}

@test "BacDive species table: the rescued TaxID is a species of its own; the genus and the invalid TaxID are not rows" {
    run species_value 21 bacdive_strains
    assert_output_equals "1"
    run species_value 21 temperature_opt
    assert_output_equals "80"
    run awk -F'\t' 'NR > 1 { print $1 }' "${BACDIVE_DIR}/BACDIVE_CONCATENATED_STRAINS_FOR_SPECIES.tsv"
    assert_output_equals "$(printf '11\n21')"
}

@test "TAXDUMP_DATE is the date of the taxdump in every row" {
    run awk -F'\t' 'NR > 1 { print $8 }' "${STATUS}"
    [[ "$(printf '%s\n' "${output}" | sort -u | wc -l)" -eq 1 ]]
}

@test "--skip-download without the taxdump is an error that says what to run" {
    mkdir -p empty/NCBI
    run bash "${PF_ROOT}/modules/normalize-ncbi-taxids.sh" -o empty --skip-download
    assert_failure
    assert_output_contains "Run: setup --update-taxdump-file"
}
