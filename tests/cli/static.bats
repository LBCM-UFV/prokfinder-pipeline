#!/usr/bin/env bats
#
# Static checks of the scripts: syntax, shellcheck, module headers, -h of every module and the catalog

setup() {
    load ../helpers/common
    pf_test_setup
}

bash_scripts() {
    printf '%s\n' "${PF_ROOT}/main-prokfinder.sh" "${PF_ROOT}/lib/common.sh" "${PF_ROOT}"/modules/*.sh "${PF_ROOT}"/docker/*.sh \
        "${PF_TESTS}/run-tests.sh" "${PF_TESTS}"/helpers/*.bash "${PF_TESTS}"/data/*.sh "${PF_TESTS}"/bin/fake-lib.bash \
        "${PF_TESTS}"/bin/{datasets,checkm2,busco,gtdbtk,skder}
}

@test "bash -n: every script has a valid syntax" {
    local FILE
    while IFS= read -r FILE; do
        run bash -n "${FILE}"
        [[ "${status}" -eq 0 ]] || { echo "syntax error in ${FILE}: ${output}" >&2; return 1; }
    done < <(bash_scripts)
}

@test "shellcheck -S warning: no warning in the scripts" {
    command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
    local -a FILES
    mapfile -t FILES < <(bash_scripts)
    run shellcheck -x -S warning "${FILES[@]}"
    assert_success
}

@test "every module has the header read by tools/build-catalog.py" {
    local FILE
    for FILE in "${PF_ROOT}"/modules/*.sh; do
        run awk 'NR == 3' "${FILE}"
        [[ "${output}" == "# $(basename "${FILE}") - Prokfinder module "* ]] \
            || { echo "line 3 of ${FILE} is not '# <file> - Prokfinder module <step>: ...': ${output}" >&2; return 1; }
        run grep -c '^# Usage:' "${FILE}"
        [[ "${output}" -ge 1 ]] || { echo "${FILE} has no '# Usage:' block" >&2; return 1; }
    done
}

@test "-h of every module" {
    local FILE
    for FILE in "${PF_ROOT}"/modules/*.sh; do
        run bash "${FILE}" -h
        [[ "${status}" -eq 0 && "${output}" == *"Usage"* ]] \
            || { echo "${FILE} -h: status ${status}, output: ${output}" >&2; return 1; }
    done
}

@test "catalog.json is up to date (tools/build-catalog.py --check)" {
    command -v python3 >/dev/null 2>&1 || skip "python3 not installed"
    run python3 "${PF_ROOT}/tools/build-catalog.py" --check
    assert_success
}
