#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ========================================================================
# Copyright (c) by Hitachi, 2024. All rights reserved.
# ========================================================================
#
# Check that data-plane services (Metadata-Gateway, S3-Gateway,
# Data-Lifecycle) are not co-located on master/admin nodes.
#
# Master nodes are identified as those running Service-Deployment
# (the cluster control-plane service).
#
# Usage: chk_service_placement.sh [health_check_dir] [services_info_log]
#

_health_check_dir="${1:-.}"
_input_file="${2:-hcpcs_services_info.log}"
_output_file="health_report_service_placement.log"

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=gsc_core.sh
. "${_script_dir}/gsc_core.sh"

_log_file_name="${_output_file}"
gsc_rotate_log "${_output_file}"

gsc_log_info "== CHECKING SERVICE PLACEMENT ON MASTER NODES =="

_services_log="$(find "${_health_check_dir}" -type f -name "${_input_file}" -print -quit 2>/dev/null || true)"

if [[ -z "${_services_log}" ]]; then
    gsc_die "Cannot find '${_input_file}' under '${_health_check_dir}'"
fi

# Master nodes run the cluster control-plane (Service-Deployment)
_master_svc="Service-Deployment"

# Data-plane services that should not run on master nodes
_flagged_services=("Metadata-Gateway" "S3-Gateway" "Data-Lifecycle")

# Parse node lines: "[1] 172.20.140.111: 12 services= Admin-App, ..."
mapfile -t _node_lines < <(grep -E '^\[[0-9]+\]' "${_services_log}" || true)

if [[ ${#_node_lines[@]} -eq 0 ]]; then
    gsc_die "No node lines found in '${_services_log}'"
fi

# Identify master nodes
declare -a _master_nodes=()
for _line in "${_node_lines[@]}"; do
    _ip=$(echo "${_line}" | awk '{print $2}' | tr -d ':' | tr -d '\n')
    _svcs=$(echo "${_line}" | sed 's/.*services= //')
    if echo "${_svcs}" | grep -q "${_master_svc}"; then
        _master_nodes+=("${_ip}")
    fi
done

if [[ ${#_master_nodes[@]} -eq 0 ]]; then
    gsc_log_warn "Could not identify master nodes (no node running ${_master_svc})"
    exit 0
fi

gsc_log_info "Master nodes (running ${_master_svc}): $(IFS=', '; echo "${_master_nodes[*]}")"

_error_count=0

for _svc in "${_flagged_services[@]}"; do
    _found_nodes=()
    for _line in "${_node_lines[@]}"; do
        _ip=$(echo "${_line}" | awk '{print $2}' | tr -d ':' | tr -d '\n')
        _svcs=$(echo "${_line}" | sed 's/.*services= //')

        # Check if node is master
        _is_master=0
        for _master in "${_master_nodes[@]}"; do
            if [[ "${_ip}" == "${_master}" ]]; then
                _is_master=1
                break
            fi
        done
        [[ "${_is_master}" -eq 0 ]] && continue

        if echo "${_svcs}" | grep -q "${_svc}"; then
            _found_nodes+=("${_ip}")
            (( _error_count++ )) || true
        fi
    done

    if [[ ${#_found_nodes[@]} -gt 0 ]]; then
        _node_list=$(IFS=', '; echo "${_found_nodes[*]}")
        if [[ ${#_found_nodes[@]} -gt 1 ]]; then
            gsc_log_error "${_svc} is running on master nodes ${_node_list} — move off master to reduce control-plane risk"
        else
            gsc_log_error "${_svc} is running on master node ${_node_list} — move off master to reduce control-plane risk"
        fi
    fi
done

if (( _error_count == 0 )); then
    gsc_log_success "No data-plane services (MDGW/S3GW/DLS) found on master nodes."
else
    gsc_log_error "${_error_count} service placement issue(s) detected on master node(s)."
fi

gsc_log_info "Saved results ${_output_file}"
