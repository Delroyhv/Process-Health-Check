#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

_health_check_dir=${1:-"."}
_input_file=${2:-"hcpcs_services_info.log"}
_output_file="health_report_services_info.log"
_dls_min=3

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${_script_dir}/gsc_core.sh"

_log_file_name="${_output_file}"
gsc_truncate_log "${_output_file}" 2
gsc_log_info "== CHECKING SERVICE'S NUMBER OF INSTANCES AND PLACEMENT =="

_services_log="$(find "${_health_check_dir}" -type f -name "${_input_file}" -print -quit 2>/dev/null || true)"

if [[ -z "${_services_log}" ]]; then
    gsc_log_warn "Cannot find '${_input_file}' under '${_health_check_dir}'; skipping service placement check."
    echo "MDGW instances: N/A"
    echo "S3GW instances: N/A"
    echo "DLS instances: N/A"
    exit 0
fi

_num_nodes="$(grep -m1 "Watchdog:" "${_services_log}" | awk '{print $2}')"
_mdgw_num="$(grep -m1 "Metadata-Gateway:" "${_services_log}" | awk '{print $2}')"
_s3gw_num="$(grep -m1 "S3-Gateway:" "${_services_log}" | awk '{print $2}')"
_dls_num="$(grep -m1 "Data-Lifecycle:" "${_services_log}" | awk '{print $2}')"

# Use printf/echo for stdout capture by runchk.sh
printf "Total nodes: %s\n" "${_num_nodes}"
printf "MDGW instances: %s\n" "${_mdgw_num}"
printf "S3GW instances: %s\n" "${_s3gw_num}"
printf "DLS instances: %s\n" "${_dls_num}"

if [[ "${_dls_num}" =~ ^[0-9]+$ ]] && (( _dls_num < _dls_min )); then
    gsc_log_warn "Number of DLS instances is too low: ${_dls_num} (min=${_dls_min})"
fi

gsc_log_success "Completed analysing services' instances."
