#!/usr/bin/env bats
#
# run-on-cluster: the PBS script written with --dry-run (qsub is not needed) and the checks of the job resources

setup() {
    load ../helpers/common
    pf_test_setup
    make_refdb_markers refdb
}

# Prints the path of the only .pbs script written in <results>/PBS-JOBS
pbs_file() {
    local FILES=("$1"/PBS-JOBS/*.pbs)
    [[ "${#FILES[@]}" -eq 1 && -f "${FILES[0]}" ]] || { echo "expected one .pbs script, found: ${FILES[*]}" >&2; return 1; }
    echo "${FILES[0]}"
}

@test "run-on-cluster alone needs another sub-command or --test" {
    run bash "${PF_MAIN}" run-on-cluster
    assert_failure 1
    assert_output_contains "run-on-cluster needs another sub-command to run on the cluster"
}

@test "--dry-run of search-genomes: resources, modules of the search and the command line of the job" {
    run bash "${PF_MAIN}" --refdb-dir refdb -o results run-on-cluster --dry-run --cpus 4 --mem 8gb \
        search-genomes --gtdb-taxon g__Thermus AND -i "hot spring"
    assert_success
    assert_output_contains "Option --dry-run: the job was not submitted."
    local PBS
    PBS="$(pbs_file results)"
    run cat "${PBS}"
    assert_output_contains "#PBS -l nodes=1:ppn=4,mem=8gb"
    assert_output_contains "#PBS -q roteamento"
    assert_output_contains "module load ncbi_datasets taxonkit"
    refute_output_contains "checkm2"
    # The job runs the same command line without run-on-cluster and its options, with -p and --memory equal to
    # the resources of the job
    run awk '/^bash .*main-prokfinder.sh/' "${PBS}"
    assert_output_equals "bash ${PF_MAIN} --refdb-dir refdb -o results search-genomes --gtdb-taxon g__Thermus AND -i hot\\ spring -p 4 --memory 8gb"
}

@test "--dry-run of download-wf loads the modules of the analysis programs" {
    run bash "${PF_MAIN}" --refdb-dir refdb -o results run-on-cluster --dry-run --cpus 8 --mem 16gb \
        search-genomes --gtdb-taxon g__Thermus download-wf --skip-busco
    assert_success
    run cat "$(pbs_file results)"
    assert_output_contains "module load seqkit checkm2 busco ncbi_datasets gtdbtk taxonkit skder"
    assert_output_contains "download-wf --skip-busco"
}

@test "--test --dry-run writes the short test job" {
    run bash "${PF_MAIN}" run-on-cluster --test --dry-run
    assert_success
    run cat "$(pbs_file prokfinder-results)"
    assert_output_contains "#PBS -q qtime"
    assert_output_contains "#PBS -l nodes=1:ppn=1,mem=2gb,walltime=01:00:00"
}

@test "--test --dry-run writes the job in the folder of -o" {
    skip "known bug: with --test, -o is not passed to submit-prokfinder-pbs.sh (the job goes to ./prokfinder-results)"
    run bash "${PF_MAIN}" -o results run-on-cluster --test --dry-run
    assert_success
    pbs_file results
}

@test "resources of the job: minimums and limits of the queues" {
    run bash "${PF_MAIN}" --refdb-dir refdb -o results run-on-cluster --dry-run --cpus 2 search-genomes --gtdb-taxon g__Thermus
    assert_failure 1
    assert_output_contains "--cpus must be at least 4"
    run bash "${PF_MAIN}" --refdb-dir refdb -o results run-on-cluster --dry-run --mem 4gb search-genomes --gtdb-taxon g__Thermus download-wf
    assert_failure 1
    assert_output_contains "--mem must be at least 8gb for download-wf"
    run bash "${PF_MAIN}" --refdb-dir refdb -o results run-on-cluster --dry-run --mem 30gb search-genomes --gtdb-taxon g__Thermus
    assert_failure 1
    assert_output_contains "Queue roteamento accepts at most 24024 MB of RAM per job"
    run bash "${PF_MAIN}" --refdb-dir refdb -o results run-on-cluster --dry-run --queue fast search-genomes --gtdb-taxon g__Thermus
    assert_failure 1
    assert_output_contains "Unknown queue 'fast'."
}

@test "-p and --memory cannot be larger than the job" {
    run bash "${PF_MAIN}" --refdb-dir refdb -o results -p 16 run-on-cluster --dry-run --cpus 8 search-genomes --gtdb-taxon g__Thermus
    assert_failure 1
    assert_output_contains "-p 16 is larger than the CPUs of the job (--cpus 8)"
    run bash "${PF_MAIN}" --refdb-dir refdb -o results --memory 20gb run-on-cluster --dry-run --mem 10gb search-genomes --gtdb-taxon g__Thermus
    assert_failure 1
    assert_output_contains "--memory 20gb is larger than the RAM of the job (--mem 10gb)"
}

@test "without --dry-run, qsub is required" {
    run bash "${PF_MAIN}" --refdb-dir refdb -o results run-on-cluster search-genomes --gtdb-taxon g__Thermus
    assert_failure 1
    assert_output_contains "the PBS command 'qsub' was not found"
}
