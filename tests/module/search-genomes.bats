#!/usr/bin/env bats
#
# search-genomes on the reference database fixture (tests/data/refdb: every Thermus and Pyrococcus assembly, the
# archaeon GCA_964347835.1 of an unnamed GTDB species and the controls Deinococcus radiodurans R1 (mesophile),
# Thermotoga maritima MSB8 and Methanocaldococcus jannaschii DSM 2661 (thermophiles outside Thermus/Pyrococcus))

setup() {
    load ../helpers/common
    pf_test_setup
}

UNNAMED_ARCHAEON="GCA_964347835.1"
D_RADIODURANS="GCA_000008565.1"
T_MARITIMA="GCA_000008545.1"
M_JANNASCHII="GCA_000091665.1"

metadata() { echo "$1/OUTPUT/GENOME-METADATA/genome-metadata.tsv"; }

# Usage: assert_selected <results> <number of genomes>
assert_selected() {
    run selected_accessions "$1"
    local N
    N="$(printf '%s' "${output}" | awk 'END { print NR }')"
    if [[ "${N}" -ne "$2" ]]; then
        echo "expected $2 selected genomes in $1, found ${N}" >&2
        return 1
    fi
}

# Usage: assert_genome_selected <results> <accession> / refute_genome_selected <results> <accession>
assert_genome_selected() {
    selected_accessions "$1" | grep -qx "$2" || { echo "$2 should be selected in $1" >&2; return 1; }
}
refute_genome_selected() {
    ! selected_accessions "$1" | grep -qx "$2" || { echo "$2 should NOT be selected in $1" >&2; return 1; }
}

############ ONE FILTER ################

@test "--gtdb-taxon g__Thermus: every GenBank assembly of the genus (table compared with tests/expected)" {
    run search_fixture thermus --gtdb-taxon g__Thermus
    assert_success
    assert_output_contains "Selected by the expression: 166"
    assert_selected thermus 166
    run awk -F'\t' 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == "SELECTED_BY_GTDB_TAXON") c = i; next } $c != "TRUE"' "$(metadata thermus)"
    assert_output_equals ""
    run selected_accessions thermus
    refute_output_contains "GCF_"
    assert_expected_tsv search-genomes/gtdb-taxon-thermus.tsv "$(metadata thermus)"
    assert_file_exists thermus/SEARCH-GENOMES-COMPLETED.txt
    assert_file_exists thermus/OUTPUT/genome-selection-query.txt
}

@test "--gtdb-taxon: case-insensitive, and without the rank prefix any rank matches" {
    search_fixture with-prefix --gtdb-taxon g__Thermus
    run search_fixture lower-case --gtdb-taxon g__thermus
    assert_success
    run search_fixture no-prefix --gtdb-taxon Thermus
    assert_success
    assert_same_file <(selected_accessions with-prefix) <(selected_accessions lower-case)
    assert_same_file <(selected_accessions with-prefix) <(selected_accessions no-prefix)
}

@test "--gtdb-taxon of a species without a name (s__CAYFZR01 sp964347835): no BacDive data" {
    run search_fixture unnamed --gtdb-taxon "s__CAYFZR01 sp964347835"
    assert_success
    assert_selected unnamed 1
    assert_genome_selected unnamed "${UNNAMED_ARCHAEON}"
    run tsv_value "$(metadata unnamed)" "${UNNAMED_ARCHAEON}" BACDIVE_LINK_LEVEL
    assert_output_equals "NULL"
}

@test "-s refseq searches the RefSeq table (GCF_ accessions only)" {
    run search_fixture refseq -s refseq --gtdb-taxon g__Thermus
    assert_success
    assert_selected refseq 151
    run selected_accessions refseq
    refute_output_contains "GCA_"
}

@test "-a and -A select the same genomes; the header of the list file is skipped" {
    printf 'accession\nGCA_000008565.1\nGCA_000008545.1\r\n\n' > list.txt
    run search_fixture by-file -A list.txt
    assert_success
    assert_output_contains "First line of 'list.txt' ('accession') taken as a header and skipped."
    search_fixture by-option -a GCA_000008565.1,GCA_000008545.1
    assert_selected by-file 2
    assert_same_file <(selected_accessions by-option) <(selected_accessions by-file)
}

@test "BacDive optimum temperature (-T 45:80): mesophile control left out" {
    run search_fixture thermophiles -T 45:80
    assert_success
    refute_genome_selected thermophiles "${D_RADIODURANS}"
    assert_expected_tsv search-genomes/temp-opt-45-80.tsv "$(metadata thermophiles)"
}

@test "BacDive growth temperature (--temp-growth 45:): thermophiles outside Thermus and Pyrococcus are kept" {
    run search_fixture growth --temp-growth 45:
    assert_success
    refute_genome_selected growth "${D_RADIODURANS}"
    assert_genome_selected growth "${T_MARITIMA}"
    assert_genome_selected growth "${M_JANNASCHII}"
}

############ AND, OR AND PARENTHESES ################

@test "A AND B is the intersection of A and B" {
    search_fixture a --gtdb-taxon g__Thermus
    search_fixture b --temp-growth 45:
    run search_fixture a-and-b --gtdb-taxon g__Thermus AND --temp-growth 45:
    assert_success
    assert_selected a-and-b 142
    assert_same_file <(comm -12 <(selected_accessions a) <(selected_accessions b)) <(selected_accessions a-and-b)
}

@test "A OR B is the union of A and B" {
    search_fixture a --gtdb-taxon g__Pyrococcus
    search_fixture b -a "${UNNAMED_ARCHAEON}"
    run search_fixture a-or-b --gtdb-taxon g__Pyrococcus OR -a "${UNNAMED_ARCHAEON}"
    assert_success
    assert_selected a-or-b 28
    assert_same_file <(LC_ALL=C sort -u <(selected_accessions a) <(selected_accessions b)) <(selected_accessions a-or-b)
}

@test "parentheses: A AND ( B OR C ) = (A AND B) OR (A AND C); AND is evaluated before OR" {
    run search_fixture grouped --gtdb-taxon g__Thermus AND "(" -O rod OR -M anaerobe ")"
    assert_success
    search_fixture ab --gtdb-taxon g__Thermus AND -O rod
    search_fixture ac --gtdb-taxon g__Thermus AND -M anaerobe
    assert_same_file <(LC_ALL=C sort -u <(selected_accessions ab) <(selected_accessions ac)) <(selected_accessions grouped)
    # Without parentheses: (A AND B) OR C
    search_fixture c -M anaerobe
    search_fixture ungrouped --gtdb-taxon g__Thermus AND -O rod OR -M anaerobe
    assert_same_file <(LC_ALL=C sort -u <(selected_accessions ab) <(selected_accessions c)) <(selected_accessions ungrouped)
    assert_expected_tsv search-genomes/thermus-and-rod-or-anaerobe.tsv "$(metadata grouped)"
}

############ INVALID VALUES ################

@test "a GTDB taxon that is not in the GTDB tables stops the search (listed in SEARCH-GENOMES-ERRORS.tsv)" {
    run search_fixture invalid --gtdb-taxon g__Notagenus
    assert_failure 1
    assert_output_contains "taxon not found in the GTDB taxonomy"
    run cat invalid/SEARCH-GENOMES-ERRORS.tsv
    assert_output_contains "$(printf 'F1\t--gtdb-taxon\tg__Notagenus\t')"
    assert_file_not_exists invalid/SEARCH-GENOMES-COMPLETED.txt
}

@test "--force-search ignores the invalid values and searches with the valid ones" {
    run search_fixture forced --force-search --gtdb-taxon g__Notagenus,g__Pyrococcus
    assert_success
    assert_selected forced 27
    run cat forced/SEARCH-GENOMES-COMPLETED.txt
    assert_output_contains "ignored_errors="
}

############ RE-EXECUTION ################

@test "the same search in the same results folder is reused; --force-selection searches again" {
    search_fixture results --gtdb-taxon g__Pyrococcus
    run search_fixture results --gtdb-taxon g__Pyrococcus
    assert_success
    assert_output_contains "did not change since the last search: reusing"
    run search_fixture results --gtdb-taxon g__Pyrococcus --force-selection
    assert_success
    refute_output_contains "reusing"
    assert_output_contains "Selected by the expression: 27"
}

@test "another query in the same results folder searches again" {
    search_fixture results --gtdb-taxon g__Pyrococcus
    run search_fixture results --gtdb-taxon g__Thermus
    assert_success
    refute_output_contains "reusing"
    assert_selected results 166
}

@test "the fixture is not changed by the searches" {
    fixture_state() { (cd "${PF_FIXTURE_REFDB}" && find . -type f -exec md5sum {} + | LC_ALL=C sort); }
    fixture_state > before.txt
    search_fixture results --gtdb-taxon g__Thermus AND --temp-growth 45:
    fixture_state > after.txt
    assert_same_file before.txt after.txt
}

############ GENOME SIZE, ASSEMBLY LEVEL, TAXID AND TAXON NAME ################

# Prints the rows of the selected genomes of <results> where the awk condition on a column fails
# Usage: rows_violating <results> <column> '<awk condition on $c that must hold>'
rows_violating() {
    awk -F'\t' -v name="$2" 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == name) c = i; next } !('"$3"')' "$(metadata "$1")"
}

@test "--genome-size <min:max> (Mb): only the genomes with that total length" {
    run search_fixture size --gtdb-taxon g__Thermus AND --genome-size 2:2.2
    assert_success
    [[ "$(selected_accessions size | wc -l)" -gt 0 ]]
    run rows_violating size ASSEMBLY_STATS_TOTAL_SEQUENCE_LENGTH '$c >= 2000000 && $c <= 2200000'
    assert_output_equals ""
    run search_fixture size-open --genome-size 3:
    assert_success
    assert_genome_selected size-open "${D_RADIODURANS}"
    run rows_violating size-open ASSEMBLY_STATS_TOTAL_SEQUENCE_LENGTH '$c >= 3000000'
    assert_output_equals ""
}

@test "--genome-size: an invalid range is listed and stops the search" {
    run search_fixture bad-size --genome-size 4
    assert_failure
    assert_output_contains "invalid range"
}

@test "--assembly-level: complete, chromosome, scaffold and contig (several values = OR)" {
    run search_fixture complete --assembly-level complete
    assert_success
    [[ "$(selected_accessions complete | wc -l)" -gt 0 ]]
    run rows_violating complete ASSEMBLY_LEVEL '$c == "Complete Genome"'
    assert_output_equals ""
    run search_fixture two --assembly-level contig,scaffold
    assert_success
    run rows_violating two ASSEMBLY_LEVEL '$c == "Contig" || $c == "Scaffold"'
    assert_output_equals ""
    [[ "$(selected_accessions two | wc -l)" -gt "$(selected_accessions complete | wc -l)" ]]
}

@test "--assembly-level: an unknown level is listed and stops the search" {
    run search_fixture bad-level --assembly-level draft
    assert_failure
    assert_output_contains "invalid assembly level"
}

@test "-t/--taxid: the TaxID of the organism or of any rank of its lineage" {
    run search_fixture strain -t 262724
    assert_success
    assert_genome_selected strain GCA_000008125.1
    refute_genome_selected strain "${D_RADIODURANS}"
    run search_fixture genus --taxid 270
    assert_success
    assert_genome_selected genus GCA_000008125.1
    assert_genome_selected genus GCA_000091545.1
    refute_genome_selected genus "${D_RADIODURANS}"
}

@test "-f/--taxid-file: a list of TaxIDs; the header is skipped" {
    printf 'taxid\n262724\n300852\n' > taxids.txt
    run search_fixture list -f taxids.txt
    assert_success
    assert_genome_selected list GCA_000008125.1
    assert_genome_selected list GCA_000091545.1
    refute_genome_selected list "${D_RADIODURANS}"
}

@test "-t: a value that is not a number is an invalid filter" {
    run search_fixture bad-taxid -t abc
    assert_failure
    assert_output_contains "invalid NCBI TaxID"
    assert_file_exists bad-taxid/SEARCH-GENOMES-ERRORS.tsv
}

@test "--ncbi-taxon and -N: the names are converted to TaxIDs with taxonkit; a name without TaxID is an invalid filter" {
    command -v taxonkit >/dev/null 2>&1 || skip "taxonkit not installed"
    cp -r "${PF_FIXTURE_REFDB}" refdb-with-taxdump
    cp -r "${PF_FIXTURE_RAW}/NCBI/TAXDUMP" refdb-with-taxdump/NCBI/TAXDUMP
    run bash "${PF_MAIN}" --refdb-dir refdb-with-taxdump -o taxon search-genomes --ncbi-taxon "Thermus thermophilus"
    assert_success
    assert_genome_selected taxon GCA_000008125.1
    assert_genome_selected taxon GCA_000091545.1
    refute_genome_selected taxon "${D_RADIODURANS}"
    printf 'Species Name\nPyrococcus horikoshii\n' > names.txt
    run bash "${PF_MAIN}" --refdb-dir refdb-with-taxdump -o names search-genomes -N names.txt
    assert_success
    assert_genome_selected names GCA_000011105.1
    run bash "${PF_MAIN}" --refdb-dir refdb-with-taxdump -o missing search-genomes --ncbi-taxon "Thermus nonexistentus"
    assert_failure
    assert_output_contains "taxon name not found in the NCBI taxonomy"
    assert_file_exists missing/SEARCH-GENOMES-ERRORS.tsv
}
