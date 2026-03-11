#!/usr/bin/env bash
#
# ========================================================================
# Copyright (c) by Hitachi Vantara, 2024. All rights reserved.
# ========================================================================
#
# Check partition split threshold configuration from support bundle output.
#
# Reads partition_split_threshold.out files collected under the support bundle.
# Validates that Metadata-Coordination and all Metadata-Gateway nodes share
# the same threshold and surfaces an ACTION when threshold is low (<16 GB)
# and partition count is high (>1500).
#
# Severity:
#   WARNING — size mismatch across MDCO/MDGW nodes
#   ACTION  — threshold < 16 GB and partition count > 1500
#   OK      — consistent threshold, no action needed
#

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${_script_dir}/gsc_core.sh"

_default_output_file="health_report_split_threshold.log"
_log_dir="."
_output_file="${_default_output_file}"

usage() {
    local _this
    _this=$(basename "$0")
    echo "\
Check partition split threshold configuration from support bundle.

${_this} [-d <dir>] [-o <output>]

  -d <dir>     directory with support bundle (default: .)
  -o <output>  output log file (default: ${_default_output_file})
"
}

getOptions() {
    while getopts "d:o:h" _opt; do
        case "${_opt}" in
            d) _log_dir="${OPTARG}" ;;
            o) _output_file="${OPTARG}" ;;
            *) usage; exit 0 ;;
        esac
    done
}

# Parse partition_split_threshold.out into pipe-separated records: SERVICE|HOST|IP|SIZE
# Handles: "IP: default SIZE" and "IP: SIZE" (no default keyword)
# Deduplicates: skips repeated blocks for the same service type (file often has duplicate sections)
_parse_threshold_file() {
    local _file="$1"
    awk '
        /^Current split threshold on / {
            host=$0
            gsub(/^Current split threshold on /, "", host)
            gsub(/:$/, "", host)
            svc=""; in_block=0
        }
        /^Metadata-/ {
            svc=$0
            gsub(/[[:space:]]*:.*$/, "", svc)   # strip ": " and trailing spaces
            if (svc in done) { in_block=0 } else { done[svc]=1; in_block=1 }
        }
        /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:/ {
            if (!in_block) next
            ip=$1; gsub(/:$/, "", ip)
            size=$NF; gsub(/[[:space:]]/, "", size)  # $NF handles both "default 1Gi" and "16Gi"
            print svc "|" host "|" ip "|" size
        }
        /^$/ || /^#/ { in_block=0 }
    ' "${_file}"
}

chk_split_threshold() {
    local _file="$1"
    local _mdco_host="" _mdco_ip="" _mdco_size=""
    local -a _mdgw_ips=() _mdgw_sizes=()
    local _mdgw_host=""

    while IFS='|' read -r _svc _host _ip _size; do
        case "${_svc}" in
            Metadata-Coordination)
                _mdco_host="${_host}"; _mdco_ip="${_ip}"; _mdco_size="${_size}" ;;
            Metadata-Gateway)
                _mdgw_host="${_host}"; _mdgw_ips+=("${_ip}"); _mdgw_sizes+=("${_size}") ;;
        esac
    done < <(_parse_threshold_file "${_file}")

    if [[ -z "${_mdco_size}" ]]; then
        gsc_loga "[ OK     ] Split threshold: Metadata-Coordination entry not found in file — skipping"
        gsc_log_warn "Split threshold: Metadata-Coordination entry not found"
        return
    fi

    local _mdco_gb="${_mdco_size%Gi} GB"  # label swap: 1Gi -> 1 GB (1:1, no arithmetic)

    gsc_loga "[ INFO   ] Split threshold host: ${_mdco_host:-${_mdgw_host}}"
    gsc_loga "[ INFO   ] Metadata-Coordination: ${_mdco_ip} — threshold: ${_mdco_gb}"
    gsc_loga "[ INFO   ] Metadata-Gateway nodes (${#_mdgw_ips[@]}):"
    local _i
    for (( _i=0; _i<${#_mdgw_ips[@]}; _i++ )); do
        gsc_loga "           ${_mdgw_ips[${_i}]} — threshold: ${_mdgw_sizes[${_i}]%Gi} GB"
    done

    # Consistency check: all MDGW sizes must match MDCO size
    local _mismatch=0
    for (( _i=0; _i<${#_mdgw_sizes[@]}; _i++ )); do
        if [[ "${_mdgw_sizes[${_i}]}" != "${_mdco_size}" ]]; then
            _mismatch=1
            gsc_loga "[WARNING ] Split threshold mismatch: ${_mdgw_ips[${_i}]} has ${_mdgw_sizes[${_i}]%Gi} GB, expected ${_mdco_gb}"
        fi
    done

    if [[ "${_mismatch}" -eq 0 ]]; then
        gsc_loga "[ OK     ] Split threshold consistent across all MDCO and MDGW nodes: ${_mdco_gb}"
        gsc_log_ok "Split threshold: all nodes consistent (${_mdco_gb})"
    else
        gsc_log_warn "Split threshold: node mismatch detected — MDCO and MDGW nodes must have the same threshold"
    fi

    # ACTION check: threshold < 16 GB and partition count > 1500
    local _thresh_num="${_mdco_size%Gi}"   # strip Gi suffix for numeric comparison
    local _part_count=0
    local _part_details_log="health_report_partition_details.log"
    if [[ -f "${_part_details_log}" ]]; then
        _part_count=$(awk '/^Count of partitions:/ { print $NF; exit }' "${_part_details_log}" || echo 0)
    fi

    local _needs_action
    _needs_action=$(awk -v thresh="${_thresh_num}" -v parts="${_part_count}" \
        'BEGIN { print (thresh+0 < 16 && parts+0 > 1500) ? "yes" : "no" }')

    gsc_loga "++++++++++++++++++++++++++++++++++++++++++++"
    if [[ "${_mismatch}" -gt 0 ]]; then
        gsc_loga "[WARNING ] Split threshold mismatch across MDCO/MDGW nodes — investigate configuration consistency"
        gsc_log_warn "Split threshold: ${#_mdgw_ips[@]} MDGW node(s) do not match MDCO threshold"
    fi
    if [[ "${_needs_action}" == "yes" ]]; then
        gsc_loga "[ACTION  ] Contact ASPSUS to increase Split threshold (current: ${_mdco_gb}, partitions: ${_part_count})"
        gsc_log_action "Split threshold too low for current partition count (${_mdco_gb} / ${_part_count} partitions) — contact ASPSUS"
    fi
    if [[ "${_mismatch}" -eq 0 && "${_needs_action}" == "no" ]]; then
        gsc_loga "[ OK     ] Split threshold configuration is consistent and appropriate"
    fi
    gsc_loga "++++++++++++++++++++++++++++++++++++++++++++"
}

############################

getOptions "$@"

gsc_log_info "== CHECKING PARTITION SPLIT THRESHOLD =="

gsc_rotate_log "${_output_file}"

# Use mapfile+sort to avoid SIGPIPE under set -euo pipefail; sort prefers
# collect_healthcheck_data/ files over standalone partition_split_threshold/ runs (c < p)
mapfile -t _threshold_files < <(find "${_log_dir}" -name '*partition_split_threshold.out' 2>/dev/null | sort)
_threshold_file="${_threshold_files[0]:-}"

if [[ -z "${_threshold_file}" ]]; then
    gsc_loga "[ OK     ] Split threshold: no partition_split_threshold.out file found — data not collected in this bundle"
    gsc_log_info "No partition_split_threshold.out found in ${_log_dir} — skipping"
    exit 0
fi

gsc_log_info "Found: ${_threshold_file}"
chk_split_threshold "${_threshold_file}"
gsc_log_info "Split threshold check complete. Output: ${_output_file}"
