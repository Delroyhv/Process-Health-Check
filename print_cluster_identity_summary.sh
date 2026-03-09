#!/usr/bin/env bash

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -r "${_script_dir}/gsc_core.sh" ]]; then
    # shellcheck disable=SC1091
    . "${_script_dir}/gsc_core.sh"
else
    echo "[ERROR] gsc_core.sh not found in ${_script_dir}" >&2
    exit 1
fi

print_cluster_identity_summary() {
    local _base_dir="."
    local _serial_file _name_file _serial _name
    local _nodes _mdgw _s3gw _dls

    if [[ -d "${_base_dir}/cluster_triage" ]]; then
        _serial_file=$(find "${_base_dir}/cluster_triage" -type f -name "cluster.serial" 2>/dev/null | sort | head -n 1)
        _name_file=$(find "${_base_dir}/cluster_triage" -type f -name "cluster.name" 2>/dev/null | sort | head -n 1)
    fi

    if [[ -n "${_serial_file:-}" && -s "${_serial_file}" ]]; then
        _serial=$(tr -d '[:space:]' < "${_serial_file}")
        [[ -z "${_serial}" ]] && _serial="N/A"
    else
        _serial="N/A"
    fi

    if [[ -n "${_name_file:-}" && -s "${_name_file}" ]]; then
        _name=$(tr -d '[:space:]' < "${_name_file}")
        [[ -z "${_name}" ]] && _name="N/A"
    else
        _name="N/A"
    fi

    # Read service counts from health_report_services*.log if available
    _nodes=$(grep -h "Total nodes:" health_report_services*.log 2>/dev/null \
             | grep -oE "[0-9]+" | head -n 1 || echo "N/A")
    _mdgw=$(grep -h "MDGW instances:" health_report_services*.log 2>/dev/null \
            | grep -oE "[0-9]+" | head -n 1 || echo "N/A")
    _s3gw=$(grep -h "S3GW instances:" health_report_services*.log 2>/dev/null \
            | grep -oE "[0-9]+" | head -n 1 || echo "N/A")
    _dls=$(grep -h "DLS instances:" health_report_services*.log 2>/dev/null \
           | grep -oE "[0-9]+" | head -n 1 || echo "N/A")
    _nodes="${_nodes:-N/A}"; _mdgw="${_mdgw:-N/A}"; _s3gw="${_s3gw:-N/A}"; _dls="${_dls:-N/A}"

    gsc_log_info "========================================"
    gsc_log_info "Serial Number : ${_serial}"
    gsc_log_info "Cluster Name  : ${_name}"
    gsc_log_info "Total Nodes   : ${_nodes}"
    gsc_log_info "MDGW          : ${_mdgw}  |  S3: ${_s3gw}  |  DLS: ${_dls}"
    gsc_log_info "========================================"
}

print_cluster_identity_summary
