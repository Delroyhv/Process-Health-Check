#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -r "${SCRIPT_DIR}/gsc_core.sh" ]]; then
    # shellcheck disable=SC1090
    . "${SCRIPT_DIR}/gsc_core.sh"
else
    echo "[ERROR] gsc_core.sh not found in ${SCRIPT_DIR}" >&2
    exit 1
fi

# shellcheck disable=SC1091
[[ -r "${SCRIPT_DIR}/os.conf" ]] && . "${SCRIPT_DIR}/os.conf"

print_node_os_summary() {
    local base_dir="."
    local files file id version os_key
    declare -A os_counts=()

    # Find files that look like *etc-os-release.out — scope to collect_healthcheck_data only
    # to avoid counting files from auxiliary node_ssh_wrapper_* collections
    files=$(find "${base_dir}/cluster_triage" -path "*/collect_healthcheck_data/*" -type f -name "*systeminfo_etc-os-release.out" 2>/dev/null)

    [[ -z "$files" ]] && return

    while IFS= read -r file; do
        id=$(grep -E '^ID=' "$file" | head -n1 | cut -d= -f2 | tr -d '"' | tr '[:lower:]' '[:upper:]')
        version=$(grep -E '^VERSION_ID' "$file" | head -n1 | cut -d= -f2 | tr -d '"' | tr -d ' ')

        [[ -z "$id" ]] && id="UNKNOWN"
        [[ -z "$version" ]] && version="UNKNOWN"

        os_key="${id} ${version}"

        if [[ -z "${os_counts[$os_key]}" ]]; then
            os_counts[$os_key]=1
        else
            os_counts[$os_key]=$(( ${os_counts[$os_key]:-0} + 1 ))
        fi
    done <<< "$files"

    gsc_log_info "Node operating system summary:"
    for os in "${!os_counts[@]}"; do
        gsc_log_info "${os_counts[$os]} nodes running: ${os}"
        if [[ -n "${_current_os:-}" ]]; then
            local _os_version="${os#* }"
            if [[ "${_os_version}" != "${_current_os}" ]]; then
                gsc_log_warn "${os_counts[$os]} nodes running ${os} need to be updated to ${_current_os}"
            fi
        fi
    done
}

print_node_os_summary
