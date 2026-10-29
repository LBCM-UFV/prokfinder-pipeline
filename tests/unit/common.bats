#!/usr/bin/env bats
#
# Unit tests of lib/common.sh: the NULL rule, the table helpers, the caches and the small parsers

setup() {
    load ../helpers/common
    pf_test_setup
}

# Prints the rule of PF_AWK_NULL for each line of stdin ("valid" when the value is kept)
null_rules() {
    pf_eval 'awk "${PF_AWK_NULL}"'\''{ r = pf_null_rule($0); print (r == "" ? "valid" : r) }'\'''
}

############ NULL RULE ############

@test "PF_AWK_NULL: empty values and dashes" {
    run null_rules <<< $'\n   \n-\n---\n - '
    assert_success
    assert_output_equals $'EMPTY\nEMPTY\nDASH\nDASH\nDASH'
}

@test "PF_AWK_NULL: invalid words, in any case" {
    run null_rules <<< $'null\nNA\nn/a\nND\nNaN\nNone\nunknown\nMissing\n NA '
    assert_success
    assert_output_equals $'INVALID_WORD\nINVALID_WORD\nINVALID_WORD\nINVALID_WORD\nINVALID_WORD\nINVALID_WORD\nINVALID_WORD\nINVALID_WORD\nINVALID_WORD'
}

@test "PF_AWK_NULL: values that start with 'not ' or 'missing '" {
    run null_rules <<< $'not applicable\nNot collected\nnot_provided\nmissing: data agreement established pre-2023\nmissing-lab'
    assert_success
    assert_output_equals $'NO_INFO_PREFIX\nNO_INFO_PREFIX\nNO_INFO_PREFIX\nNO_INFO_PREFIX\nNO_INFO_PREFIX'
}

@test "PF_AWK_NULL: real values are kept" {
    run null_rules <<< $'Thermus aquaticus\nnothing\nnotable\nNAD\n0\n-5\nhot spring\nmissingness\nna-1'
    assert_success
    assert_output_equals $'valid\nvalid\nvalid\nvalid\nvalid\nvalid\nvalid\nvalid\nvalid'
}

############ format_tsv ############

@test "format_tsv: cells trimmed, invalid values to NULL, rows padded and cut to the header" {
    printf 'acc\tIsolation source\tcountry\r\nGCA_1.1\t hot spring \tnot collected\r\nGCA_2.1\tNA\nGCA_3.1\t-\tBrazil\textra\n' > in.tsv
    run pf_eval 'format_tsv 0 < in.tsv'
    assert_success
    assert_output_equals "$(printf 'acc\tIsolation_source\tcountry\nGCA_1.1\thot spring\tNULL\nGCA_2.1\tNULL\tNULL\nGCA_3.1\tNULL\tBrazil')"
}

@test "format_tsv: upper-case header" {
    printf 'Assembly BioSample Isolation source\tgc (%%)\n' > in.tsv
    run pf_eval 'format_tsv 1 < in.tsv'
    assert_success
    assert_output_equals "$(printf 'ASSEMBLY_BIOSAMPLE_ISOLATION_SOURCE\tGC')"
}

@test "format_tsv + pf_write_null_mapping: converted values summed and sorted" {
    printf 'acc\tsource\tcountry\nA\tNA\t\nB\tNA\tnot collected\nC\t-\tnot collected\nD\tNA\tBrazil\n' > in.tsv
    run pf_eval 'format_tsv 0 rows1.tsv TABLE1 < in.tsv > out.tsv && format_tsv 0 rows2.tsv TABLE1 < in.tsv > /dev/null && pf_write_null_mapping NULL-VALUES.tsv rows1.tsv rows2.tsv && cat NULL-VALUES.tsv'
    assert_success
    assert_output_equals "$(printf '%s\n' \
        $'SOURCE_TABLE\tCOLUMN\tORIGINAL_VALUE\tRULE\tCONVERTED_TO\tOCCURRENCES' \
        $'TABLE1\tcountry\tnot collected\tNO_INFO_PREFIX\tNULL\t4' \
        $'TABLE1\tcountry\t(empty)\tEMPTY\tNULL\t2' \
        $'TABLE1\tsource\tNA\tINVALID_WORD\tNULL\t6' \
        $'TABLE1\tsource\t-\tDASH\tNULL\t2')"
}

@test "format_tsv: a cell that is already NULL is not counted as converted" {
    printf 'acc\tx\nA\tNULL\n' > in.tsv
    run pf_eval 'format_tsv 0 rows.tsv T < in.tsv'
    assert_success
    assert_output_equals "$(printf 'acc\tx\nA\tNULL')"
    [[ ! -s rows.tsv ]]
}

############ add_metadata_columns ############

@test "add_metadata_columns: new columns added, missing accessions and empty cells get NULL" {
    printf 'ASSEMBLY_ACCESSION\tSPECIES\nGCA_1.1\tT. aquaticus\nGCA_2.1\tP. furiosus\n' > master.tsv
    printf 'ASSEMBLY_ACCESSION\tN50\tCONTIGS\nGCA_1.1\t1000\t\n' > step.tsv
    run pf_eval 'add_metadata_columns master.tsv step.tsv && cat master.tsv'
    assert_success
    assert_output_equals "$(printf 'ASSEMBLY_ACCESSION\tSPECIES\tN50\tCONTIGS\nGCA_1.1\tT. aquaticus\t1000\tNULL\nGCA_2.1\tP. furiosus\tNULL\tNULL')"
}

@test "add_metadata_columns: running a step again replaces its columns" {
    printf 'ASSEMBLY_ACCESSION\tN50\tSPECIES\nGCA_1.1\t1\tT. aquaticus\n' > master.tsv
    printf 'ASSEMBLY_ACCESSION\tN50\nGCA_1.1\t2000\n' > step.tsv
    run pf_eval 'add_metadata_columns master.tsv step.tsv && add_metadata_columns master.tsv step.tsv && cat master.tsv'
    assert_success
    assert_output_equals "$(printf 'ASSEMBLY_ACCESSION\tSPECIES\tN50\nGCA_1.1\tT. aquaticus\t2000')"
}

@test "add_metadata_columns: an empty table leaves the master unchanged (warning)" {
    printf 'ASSEMBLY_ACCESSION\tSPECIES\nGCA_1.1\tx\n' > master.tsv
    : > step.tsv
    run pf_eval 'add_metadata_columns master.tsv step.tsv'
    assert_success
    assert_output_contains "[WARNING]"
    run cat master.tsv
    assert_output_equals "$(printf 'ASSEMBLY_ACCESSION\tSPECIES\nGCA_1.1\tx')"
}

############ COLUMNS AND ROWS ############

@test "get_column_index: case and punctuation are ignored; alternative names" {
    printf 'Assembly Accession\tgtdb-taxonomy\tGC\n' > t.tsv
    run pf_eval 'get_column_index t.tsv ASSEMBLY_ACCESSION'
    assert_output_equals "1"
    run pf_eval 'get_column_index t.tsv GTDB_TAXONOMY'
    assert_output_equals "2"
    run pf_eval 'get_column_index t.tsv gc_percent GC'
    assert_output_equals "3"
    run pf_eval 'get_column_index t.tsv NOT_A_COLUMN'
    assert_success
    assert_output_equals ""
}

@test "require_column: stops with a clear message when the column is missing" {
    printf 'a\tb\n' > t.tsv
    run pf_eval 'require_column t.tsv SPECIES'
    assert_failure 1
    assert_output_contains "Column 'SPECIES' not found in t.tsv"
}

@test "select_accessions: rows whose column has one of the values" {
    printf 'ACC\tPASS\nA\tyes\nB\tno\nC\tyes\nD\tNULL\n' > t.tsv
    run pf_eval 'select_accessions t.tsv PASS yes NULL'
    assert_success
    assert_output_equals $'A\nC\nD'
}

@test "count_records and count_lines" {
    printf 'h\n1\n2\n' > t.tsv
    run pf_eval 'count_records t.tsv; : > empty.tsv; count_records empty.tsv; count_lines t.tsv; count_lines missing.tsv'
    assert_success
    assert_output_equals $'2\n0\n3\n0'
}

@test "genome_file_of: .fna first, then .fna.gz, nothing when missing" {
    mkdir g
    touch g/A.fna g/A.fna.gz g/B.fna.gz
    run pf_eval 'genome_file_of g A; genome_file_of g B; genome_file_of g C'
    assert_success
    assert_output_equals $'g/A.fna\ng/B.fna.gz'
}

############ CACHES ############

@test "pending_for_cache: only new genomes and genomes whose file changed" {
    printf 'ACC\tMTIME\tRESULT\nA\t100\tok\nB\t100\tok\n' > cache.tsv
    printf 'A\ta.fna\t100\nB\tb.fna\t200\nC\tc.fna\t100\n' > genomes.tsv
    run pf_eval 'pending_for_cache cache.tsv genomes.tsv'
    assert_success
    assert_output_equals "$(printf 'B\tb.fna\t200\nC\tc.fna\t100')"
}

@test "update_cache: new rows replace the old ones of the same genome; rows sorted" {
    printf 'ACC\tMTIME\tRESULT\nC\t100\told\nA\t100\tok\n' > cache.tsv
    printf 'C\t200\tnew\nB\t100\tok\n' > new.tsv
    run pf_eval 'update_cache cache.tsv new.tsv && cat cache.tsv'
    assert_success
    assert_output_equals "$(printf 'ACC\tMTIME\tRESULT\nA\t100\tok\nB\t100\tok\nC\t200\tnew')"
}

############ RESOURCES, LOG AND TEMPORARY FOLDERS ############

@test "pf_memory_gb: GB, MB and plain numbers; invalid formats fail" {
    run pf_eval 'pf_memory_gb 20gb; pf_memory_gb 20G; pf_memory_gb 16; pf_memory_gb 24000mb; pf_memory_gb 08'
    assert_success
    assert_output_equals $'20\n20\n16\n23\n8'
    run pf_eval 'pf_memory_gb 2tb'
    assert_failure
    run pf_eval 'pf_memory_gb abc'
    assert_failure
}

@test "pf_citation: every component of versions.tsv has a citation, and every DOI is in CITATIONS.md" {
    local COMPONENT DOI
    for COMPONENT in prokfinder datasets seqkit pyrodigal checkm2 busco gtdbtk skder cidder Rscript \
            NCBI BACDIVE GTDB checkm2-database busco-lineages gtdbtk-reference; do
        run pf_eval "pf_citation ${COMPONENT}"
        [[ -n "${output}" ]] || { echo "no citation for ${COMPONENT}" >&2; return 1; }
        for DOI in $(printf '%s\n' "${output}" | tr ';' '\n' | awk '$1 ~ /^10\./ { print $1 }'); do
            grep -qF "doi.org/${DOI})" "${PF_ROOT}/CITATIONS.md" || { echo "${DOI} (${COMPONENT}) not in CITATIONS.md" >&2; return 1; }
        done
    done
    run pf_eval 'pf_citation unknown-program'
    assert_output_equals ""
}

@test "die: logs the error and exits with the given code" {
    run pf_eval 'die "something failed" 3'
    assert_failure 3
    assert_output_contains "[ERROR] something failed"
}

@test "make_temp_dir: the folder is removed when the script ends" {
    run pf_eval 'make_temp_dir D; touch "${D}/file"; echo "${D}"'
    assert_success
    [[ -n "${output}" ]]
    assert_file_not_exists "${output}"
}

@test "pf_refdb_format_ok: checks the format recorded in the checkpoint" {
    mkdir db
    printf 'date=2026-10-24\nformat=3\n' > db/COMPLETED-DOWNLOAD.txt
    run pf_eval 'pf_refdb_format_ok db 3'
    assert_success
    run pf_eval 'pf_refdb_format_ok db 4'
    assert_failure
    run pf_eval 'pf_refdb_format_ok missing-db 3'
    assert_failure
}

@test "Zenodo registry: host, record and the package of a database and format" {
    printf '# comment
HOST	h.test
RECORD	42
PACKAGE	GTDB	3	old.tar.gz	aaa
PACKAGE	GTDB	4	new.tar.gz	bbb
' > registry.tsv
    run pf_eval 'pf_registry_value registry.tsv HOST; pf_registry_value registry.tsv RECORD'
    assert_output_equals $'h.test
42'
    run pf_eval 'pf_registry_package registry.tsv GTDB 4'
    assert_output_equals $'new.tar.gz	bbb'
    run pf_eval 'pf_registry_package registry.tsv GTDB 5'
    assert_output_equals ""
}

@test "pf_refdb_from_package: only checkpoints with a package line" {
    mkdir -p a b
    printf 'format=3
' > a/COMPLETED-DOWNLOAD.txt
    printf 'format=3
package=zenodo:1:x.tar.gz
' > b/COMPLETED-DOWNLOAD.txt
    run pf_eval 'pf_refdb_from_package a'
    assert_failure 1
    run pf_eval 'pf_refdb_from_package b'
    assert_success
}

@test "pf_version_ge: compares versions number by number" {
    run pf_eval 'pf_version_ge 1.3.8 1.3.7'
    assert_success
    run pf_eval 'pf_version_ge 1.3.7 1.3.7'
    assert_success
    run pf_eval 'pf_version_ge 1.3.10 1.3.7'
    assert_success
    run pf_eval 'pf_version_ge 1.3.6 1.3.7'
    assert_failure 1
    run pf_eval 'pf_version_ge 1.2.9 1.3.7'
    assert_failure 1
}

@test "pf_marker_value: first value of a key, nothing when the key or the checkpoint is missing" {
    mkdir -p a
    printf 'format=3\nrelease=v232\nrelease=v233\n' > a/COMPLETED-DOWNLOAD.txt
    run pf_eval 'pf_marker_value a release'
    assert_success
    assert_output_equals "v232"
    run pf_eval 'pf_marker_value a package'
    assert_success
    assert_output_equals ""
    run pf_eval 'pf_marker_value missing release'
    assert_success
    assert_output_equals ""
}

@test "pf_refdb_package_current: a newer package in the registry (record, file or MD5) is found" {
    printf 'RECORD\t42\nPACKAGE\tGTDB\t4\tnew.tar.gz\tbbb\n' > registry.tsv
    mkdir -p same old-file no-md5 other-md5
    printf 'format=4\npackage=zenodo:42:new.tar.gz\npackage_md5=bbb\n' > same/COMPLETED-DOWNLOAD.txt
    printf 'format=4\npackage=zenodo:42:old.tar.gz\npackage_md5=bbb\n' > old-file/COMPLETED-DOWNLOAD.txt
    printf 'format=4\npackage=zenodo:42:new.tar.gz\n' > no-md5/COMPLETED-DOWNLOAD.txt
    printf 'format=4\npackage=zenodo:42:new.tar.gz\npackage_md5=aaa\n' > other-md5/COMPLETED-DOWNLOAD.txt
    run pf_eval 'pf_refdb_package_current registry.tsv GTDB 4 same'
    assert_success
    run pf_eval 'pf_refdb_package_current registry.tsv GTDB 4 no-md5'
    assert_success
    run pf_eval 'pf_refdb_package_current registry.tsv GTDB 4 old-file'
    assert_failure 1
    run pf_eval 'pf_refdb_package_current registry.tsv GTDB 4 other-md5'
    assert_failure 1
    # (no package of the format in the registry: nothing to replace)
    run pf_eval 'pf_refdb_package_current registry.tsv GTDB 5 old-file'
    assert_success
}

@test "reference database paths" {
    run pf_eval 'pf_gtdb_taxonomy_table G ARCHAEA; pf_gtdb_metadata_table G BACTERIA; pf_ncbi_metadata_table N BACTERIA genbank'
    assert_success
    assert_output_equals $'G/ARCHAEA-GTDB-TAXONOMY/ar53_taxonomy_formatted.tsv\nG/BACTERIA-GTDB-METADATA/bac120_metadata_formatted.tsv\nN/BACTERIA-NCBI-METADATA/genbank-metadata.tsv'
}

@test "pf_help_box: title, two columns with the description wrapped, plain text and bullets, every line of the same width" {
    run pf_eval 'pf_help_box "Options" <<EOF
  -j, --jobs <n>   Number of jobs, a long description that must be wrapped in more than one line of the box
  --flag           Short
                   continued here
  (a plain note that is also long enough to need wrapping inside the box, with no columns at all)
  - a bullet that is long enough to wrap, and its second line must be indented under the text of the bullet
EOF'
    assert_success
    assert_output_contains "╭─ Options ─"
    assert_output_contains "│ -j, --jobs <n>  Number of jobs, a long description that must be"
    assert_output_contains "│ --flag          Short continued here"
    assert_output_contains "│ - a bullet that is long enough to wrap"
    assert_output_contains "│   "
    [[ "$(printf '%s
' "${output}" | line_widths)" == "80" ]]
    [[ "$(printf '%s
' "${output}" | awk 'NR == 1')" == "╭"* ]]
    [[ "$(printf '%s
' "${output}" | awk 'END { print }')" == "╰"* ]]
}
