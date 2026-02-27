#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -r "${SCRIPT_DIR}/gsc_core.sh" ]]; then
    # shellcheck disable=SC1090
    . "${SCRIPT_DIR}/gsc_core.sh"
else
    echo "[ERROR] gsc_core.sh not found in ${SCRIPT_DIR}" >&2
    exit 1
fi

print_cluster_identity_summary() {
    local base_dir="."
    local serial_file name_file serial name

    if [[ -d "${base_dir}/cluster_triage" ]]; then
        serial_file=$(find "${base_dir}/cluster_triage" -type f -name "cluster.serial" 2>/dev/null | head -n 1)
        name_file=$(find "${base_dir}/cluster_triage" -type f -name "cluster.name" 2>/dev/null | head -n 1)
    else
        serial_file=""
        name_file=""
    fi

    if [[ -n "${serial_file}" && -s "${serial_file}" ]]; then
        serial=$(head -n 1 "${serial_file}")
    else
        serial="unknown"
    fi

    if [[ -n "${name_file}" && -s "${name_file}" ]]; then
        name=$(head -n 1 "${name_file}")
    else
        name="unknown"
    fi

    gsc_log_info "------------------------------------------------"
    gsc_log_info "Cluster identity summary:"
    gsc_log_info "Cluster serial (from cluster.serial): ${serial}"
    gsc_log_info "Cluster name   (from cluster.name): ${name}"
    gsc_log_info "------------------------------------------------"
}

print_cluster_identity_summary
