#!/usr/bin/env bats
#
# Command line of main-prokfinder.sh: help, errors and the checks made before a run. No reference database or
# analysis program is needed (the databases are only checkpoints written by make_refdb_markers).

setup() {
    load ../helpers/common
    pf_test_setup
}

# A command line error prints only the message and the -h to read (never the whole help)
assert_cli_error() {
    assert_failure 1
    assert_output_contains "[ERROR] $1"
    assert_output_contains "-h (or --help) to see the options."
    refute_output_contains "Usage:"
}

############ HELP ############

@test "-h shows the main help" {
    run bash "${PF_MAIN}" -h
    assert_success
    assert_output_contains "Usage: main-prokfinder.sh <sub-command> [options]"
    assert_output_contains "run-on-cluster"
}

@test "-h of each sub-command" {
    local SUB
    for SUB in setup search-genomes download-wf run-on-cluster; do
        run bash "${PF_MAIN}" "${SUB}" -h
        assert_success
        assert_output_contains "Usage: main-prokfinder.sh ${SUB}"
    done
}

@test "--help is the same as -h" {
    run bash "${PF_MAIN}" search-genomes -h
    local HELP="${output}"
    run bash "${PF_MAIN}" search-genomes --help
    assert_success
    assert_output_equals "${HELP}"
}

############ ERRORS IN THE COMMAND LINE ############

@test "no sub-command" {
    run bash "${PF_MAIN}"
    assert_cli_error "No sub-command given."
}

@test "unknown sub-command and unknown option" {
    run bash "${PF_MAIN}" search
    assert_cli_error "Unknown sub-command: 'search'."
    run bash "${PF_MAIN}" search-genomes --not-an-option
    assert_cli_error "Unknown option: '--not-an-option'."
}

@test "a sub-command given twice" {
    run bash "${PF_MAIN}" setup setup
    assert_cli_error "The sub-command setup was given more than once."
}

@test "an option of another sub-command" {
    run bash "${PF_MAIN}" --gtdb-taxon g__Thermus
    assert_cli_error "Option --gtdb-taxon belongs to the sub-command search-genomes: write it after the sub-command"
    run bash "${PF_MAIN}" search-genomes --gtdb-taxon g__Thermus --min-n50 1000
    assert_cli_error "Option --min-n50 belongs to the sub-command download-wf, not to search-genomes."
}

@test "an option without its value" {
    run bash "${PF_MAIN}" search-genomes --gtdb-taxon
    assert_cli_error "Option --gtdb-taxon requires a value."
    run bash "${PF_MAIN}" search-genomes --gtdb-taxon -T 45:80
    assert_cli_error "Option --gtdb-taxon requires a value."
}

@test "a negative number is a value, not an option" {
    run bash "${PF_MAIN}" search-genomes -T -5:10
    refute_output_contains "requires a value"
}

@test "an argument that is not an option nor a value (values with spaces without quotes)" {
    run bash "${PF_MAIN}" search-genomes -i hot spring
    assert_cli_error "Unexpected argument 'spring'"
}

############ SELECTION FILTERS (AND/OR) ############

@test "search-genomes without filters" {
    run bash "${PF_MAIN}" search-genomes
    assert_cli_error "search-genomes needs at least one selection filter."
}

@test "two filters without AND/OR" {
    run bash "${PF_MAIN}" search-genomes -T 45:80 -O rod
    assert_cli_error "AND or OR is missing between -T and -O."
}

@test "AND/OR in the wrong place" {
    run bash "${PF_MAIN}" search-genomes AND -T 45:80
    assert_cli_error "AND must be between two selection filters"
    run bash "${PF_MAIN}" search-genomes -T 45:80 OR
    assert_cli_error "The selection filters cannot end with AND, OR or '('."
    run bash "${PF_MAIN}" setup AND
    assert_cli_error "'AND' is only used between the selection filters of search-genomes."
}

@test "parentheses must be balanced" {
    run bash "${PF_MAIN}" search-genomes "(" -T 45:80 OR -O rod
    assert_cli_error "'(' without ')' in the selection filters."
    run bash "${PF_MAIN}" search-genomes -T 45:80 ")"
    assert_cli_error "')' without '('."
    run bash "${PF_MAIN}" search-genomes -T 45:80 "("
    assert_cli_error "AND or OR is missing between -T and '('."
}

@test "invalid -s/--assembly-source" {
    run bash "${PF_MAIN}" search-genomes -s ena --gtdb-taxon g__Thermus
    assert_cli_error "Invalid -s/--assembly-source 'ena'. Must be genbank or refseq."
}

############ RESOURCES AND download-wf OPTIONS ############

@test "invalid -p and --memory" {
    run bash "${PF_MAIN}" -p 0 setup
    assert_cli_error "Invalid number of threads '-p 0'."
    run bash "${PF_MAIN}" --memory lots setup
    assert_cli_error "Invalid --memory 'lots'."
    run bash "${PF_MAIN}" --memory 512mb setup
    assert_cli_error "Invalid --memory '512mb'."
}

@test "invalid values of download-wf" {
    run bash "${PF_MAIN}" download-wf -j 31
    assert_cli_error "Invalid -j/--download-threads '31'."
    run bash "${PF_MAIN}" download-wf --min-contig-length 1k
    assert_cli_error "Invalid --min-contig-length '1k'."
    run bash "${PF_MAIN}" download-wf --max-contigs 10.5
    assert_cli_error "Invalid --max-contigs '10.5'."
    run bash "${PF_MAIN}" download-wf --min-completeness 101
    assert_cli_error "Invalid --min-completeness '101'."
    run bash "${PF_MAIN}" download-wf --derep-mode fast
    assert_cli_error "Invalid --derep-mode 'fast'."
    run bash "${PF_MAIN}" download-wf --derep-method fastani
    assert_cli_error "Invalid --derep-method 'fastani'."
    run bash "${PF_MAIN}" download-wf --derep-ani 0
    assert_cli_error "Invalid --derep-ani '0'."
}

@test "--option=value is the same as --option value" {
    run bash "${PF_MAIN}" download-wf --derep-mode=fast
    assert_cli_error "Invalid --derep-mode 'fast'."
}

############ REFERENCE DATABASES AND ORDER OF THE SUB-COMMANDS ############

@test "search-genomes without the reference databases" {
    run bash "${PF_MAIN}" search-genomes --gtdb-taxon g__Thermus
    assert_cli_error "Reference databases not found in ${HOME}/prokfinder-refdb (missing: NCBI BACDIVE GTDB)."
    assert_output_contains "Install them first with: main-prokfinder.sh setup"
}

@test "--refdb-dir is where the databases are looked for" {
    make_refdb_markers refdb
    rm refdb/BACDIVE/COMPLETED-DOWNLOAD.txt
    run bash "${PF_MAIN}" --refdb-dir refdb search-genomes --gtdb-taxon g__Thermus
    assert_cli_error "Reference databases not found in refdb (missing: BACDIVE)."
}

@test "reference databases of an older format must be rebuilt with setup" {
    make_refdb_markers refdb
    printf 'format=1\n' > refdb/GTDB/COMPLETED-DOWNLOAD.txt
    run bash "${PF_MAIN}" --refdb-dir refdb search-genomes --gtdb-taxon g__Thermus
    assert_cli_error "The reference databases in refdb were installed by an older version of Prokfinder (tables to update: GTDB)."
    assert_output_contains "rebuilt from the files already downloaded"
}

@test "download-wf needs the genomes selected by search-genomes" {
    make_refdb_markers refdb
    run bash "${PF_MAIN}" --refdb-dir refdb -o results download-wf
    assert_cli_error "download-wf needs the genomes selected by search-genomes, but results/SEARCH-GENOMES-COMPLETED.txt was not found."
}

@test "setup --from-source over installed databases without a terminal stops" {
    make_refdb_markers refdb
    rm refdb/GTDB/COMPLETED-DOWNLOAD.txt
    run bash "${PF_MAIN}" --refdb-dir refdb -o results setup --from-source
    assert_cli_error "setup --from-source with reference databases already installed is a full update: NCBI BACDIVE will be downloaded again"
    assert_output_contains "It must be confirmed on a terminal"
    assert_file_not_exists results
}

@test "setup --from-source over installed databases asks on a terminal; an answer other than y changes nothing" {
    make_refdb_markers refdb
    run_on_terminal n --refdb-dir refdb -o results setup --from-source
    assert_failure 1
    assert_output_contains "is a full update: NCBI BACDIVE GTDB will be downloaded again"
    assert_output_contains "Continue? [y/N]"
    assert_output_contains "Full update cancelled: nothing was changed."
    assert_file_not_exists results
}

@test "setup --from-source without installed databases needs no confirmation" {
    run bash "${PF_MAIN}" --refdb-dir refdb -o results run-on-cluster --dry-run setup --from-source
    assert_success
    refute_output_contains "full update"
}

@test "setup --from-source goes on with an interrupted first installation without a full update" {
    make_refdb_markers refdb
    rm refdb/GTDB/COMPLETED-DOWNLOAD.txt
    printf 'NCBI\nBACDIVE\nGTDB\n' > refdb/.from-source-install.state
    run bash "${PF_MAIN}" --refdb-dir refdb -o results run-on-cluster --dry-run setup --from-source
    assert_success
    refute_output_contains "full update"
}

@test "--from-source belongs to setup" {
    run bash "${PF_MAIN}" search-genomes --from-source
    assert_cli_error "Option --from-source belongs to the sub-command setup, not to search-genomes."
}

@test "a command line error writes nothing in the results folder" {
    run bash "${PF_MAIN}" -o results search-genomes -T 45:80 -O rod
    assert_failure 1
    assert_file_not_exists results
}

############ --check ############

@test "--check lists the dependencies and exits" {
    run bash "${PF_MAIN}" --check
    [[ "${status}" -eq 0 || "${status}" -eq 1 ]]
    local TOOL
    for TOOL in datasets taxonkit seqkit checkm2 busco gtdbtk skder; do
        assert_output_contains "${TOOL}"
    done
    assert_file_not_exists prokfinder-results
}

############ HELP IN BOXES, REMOVED AND RENAMED OPTIONS ############

@test "the help of each sub-command is written in boxes with the same width" {
    local SUB WIDTHS
    for SUB in "" setup search-genomes download-wf run-on-cluster; do
        run bash "${PF_MAIN}" ${SUB} -h
        assert_success
        assert_output_contains "╭─ Global options"
        WIDTHS="$(printf '%s\n' "${output}" | line_widths)"
        [[ "${WIDTHS}" == "80" ]] || { echo "sub-command '${SUB}': box lines of width ${WIDTHS}" >&2; return 1; }
    done
}

@test "-h of search-genomes: NCBI filters in a box, with TaxID, genome size and assembly level, without country" {
    run bash "${PF_MAIN}" search-genomes -h
    assert_success
    assert_output_contains "╭─ NCBI filters"
    assert_output_contains "--taxid <id>"
    assert_output_contains "--ncbi-taxon-file <file>"
    assert_output_contains "--genome-size <min:max>"
    assert_output_contains "--assembly-level <level>"
    refute_output_contains "country"
}

@test "-h of download-wf: --export-all-hq in the Export box" {
    run bash "${PF_MAIN}" download-wf -h
    assert_success
    assert_output_contains "Export (OUTPUT/GENOME-DATABASE"
    assert_output_contains "--export-all-hq"
}

@test "-h of setup is short and has only --from-source" {
    run bash "${PF_MAIN}" setup -h
    assert_success
    assert_output_contains "from Zenodo and adds them to the reference"
    assert_output_contains "--from-source"
    refute_output_contains "--yes"
    refute_output_contains "--ncbi-complete-metadata"
    refute_output_contains "--refdb-registry"
}

@test "removed options: --country, --country-file, -z/--gzip and --results-dir are unknown" {
    local OPTION
    for OPTION in -c --country -C --country-file; do
        run bash "${PF_MAIN}" search-genomes "${OPTION}" Brazil
        assert_cli_error "Unknown option: '${OPTION}'."
    done
    for OPTION in -z --gzip; do
        run bash "${PF_MAIN}" download-wf "${OPTION}"
        assert_cli_error "Unknown option: '${OPTION}'."
    done
    run bash "${PF_MAIN}" --results-dir x download-wf
    assert_cli_error "Unknown option: '--results-dir'."
}

@test "--output-dir is the output directory" {
    make_refdb_markers refdb
    run bash "${PF_MAIN}" --refdb-dir refdb --output-dir out download-wf
    assert_cli_error "download-wf needs the genomes selected by search-genomes, but out/SEARCH-GENOMES-COMPLETED.txt was not found."
}

@test "--derep-ani and --derep-mode are ignored with cidder, with a warning" {
    make_refdb_markers refdb
    run bash "${PF_MAIN}" --refdb-dir refdb -o results download-wf --derep-method cidder --derep-ani 99 --derep-mode dynamic
    assert_output_contains "[WARNING] --derep-ani --derep-mode ignored: they are options of skDER, and --derep-method is cidder."
    run bash "${PF_MAIN}" --refdb-dir refdb -o results download-wf --derep-ani 99
    refute_output_contains "ignored: they are options of skDER"
}

@test "the resources used by the programs are logged only inside a PBS job" {
    make_refdb_markers refdb
    run bash "${PF_MAIN}" --refdb-dir refdb -o results -p 2 --memory 3gb search-genomes -G 40:65
    assert_output_contains "Reference databases folder:"
    refute_output_contains "Resources used by the programs"
    run env PBS_JOBID=1.fake NCPUS=4 bash "${PF_MAIN}" --refdb-dir refdb -o results -p 2 --memory 3gb search-genomes -G 40:65
    assert_output_contains "PBS job 1.fake on"
    assert_output_contains "Resources used by the programs: 2 CPU(s), 3 GB of RAM"
}

@test "default output directory that already has results: asks before a new search; -o is not asked" {
    make_refdb_markers refdb
    mkdir prokfinder-results
    echo old > prokfinder-results/prokfinder.log
    run_on_terminal n --refdb-dir refdb search-genomes -G 40:65
    assert_failure 1
    assert_output_contains "already has the results of a previous run"
    assert_output_contains "Run in the same output directory? [y/N]"
    assert_output_contains "Nothing was run."
    run cat prokfinder-results/prokfinder.log
    assert_output_equals "old"
    mkdir other
    echo old > other/prokfinder.log
    run_on_terminal n --refdb-dir refdb -o other search-genomes -G 40:65
    refute_output_contains "Run in the same output directory?"
}
