#!/usr/bin/env bash
#
# ========================================================================
# Copyright (c) by Hitachi Vantara, 2024. All rights reserved.
# ========================================================================
#
# Parse collected iostat diagnostic files from cluster nodes. Produces a
# per-node, per-device summary of I/O utilization, throughput, and latency.
# Averages all intervals found in the file; flags devices exceeding thresholds.
#
# Thresholds (Red Hat Enterprise Linux Performance Tuning Guide,
# and Brendan Gregg "Systems Performance" USE method):
#
#   %util  > 75%   : WARNING  — device approaching saturation; I/O queuing
#                               likely; review workload distribution
#   %util  > 90%   : CRITICAL — device saturated; application stalls probable;
#                               redistribute I/O or add capacity
#   await  > 20 ms : WARNING  — elevated latency; check for competing
#                               workloads or misconfigured I/O scheduler
#                               (use mq-deadline or none for NVMe/SSD)
#   await  > 100 ms: CRITICAL — severe latency; check dmesg for errors,
#                               verify storage path health
#   aqu-sz >= 8    : WARNING  — deep I/O queue; device overwhelmed;
#                               tune nr_requests or throttle workload
#
# References:
#   Red Hat Enterprise Linux 8 Performance Tuning Guide — Storage I/O
#     https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/
#     8/html/monitoring_and_managing_system_status_and_performance/
#     assembly_overview-of-performance-monitoring-options_monitoring-and-
#     managing-system-status-and-performance
#   Brendan Gregg, "Systems Performance: Enterprise and the Cloud", 2nd ed.
#     Chapter 9: Disks — USE method (%util = utilization, aqu-sz = saturation)
#   iostat(1) sysstat — extended statistics (-x): await, aqu-sz, %util
#

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${_script_dir}/gsc_core.sh"

_default_output_file="health_report_disk_perf.log"
_log_dir="."
_output_file="${_default_output_file}"
_err=0

# Thresholds (override via environment variable)
_UTIL_WARN=${DISK_UTIL_WARN:-75}
_UTIL_CRIT=${DISK_UTIL_CRIT:-90}
_AWAIT_WARN=${DISK_AWAIT_WARN:-20}
_AWAIT_CRIT=${DISK_AWAIT_CRIT:-100}
_QUEUE_WARN=${DISK_QUEUE_WARN:-8}

usage() {
    local _this_filename
    _this_filename=$(basename "$0")
    echo "\
Parse iostat disk I/O diagnostics across all cluster nodes.

${_this_filename} [-d <dir>] [-o <output>]

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

# _cmp_float VAL THRESHOLD — returns 0 (true) if VAL >= THRESHOLD (awk float compare)
_cmp_float() {
    awk -v v="$1" -v t="$2" 'BEGIN { exit !(v+0 >= t+0) }'
}

############################

getOptions "$@"

gsc_log_info "== CHECKING DISK PERFORMANCE =="
gsc_rotate_log "${_output_file}"

mapfile -t _iostat_files < <(find "${_log_dir}" -name '*iostat*.out' \
    ! -name '*.err' 2>/dev/null | sort)

if [[ "${#_iostat_files[@]}" -eq 0 ]]; then
    gsc_loga "WARNING: No iostat diagnostic files found in ${_log_dir}"
    exit 0
fi

gsc_log_info "Found ${#_iostat_files[@]} node(s) with iostat diagnostics"

_hdr=$(printf '%-34s %-7s %-7s %-8s %-8s %-10s %-7s' \
    "Node/Device" "r/s" "w/s" "rkB/s" "wkB/s" "await(ms)" "%util")
_sep=$(printf '%-34s %-7s %-7s %-8s %-8s %-10s %-7s' \
    "-----------" "---" "---" "-----" "-----" "---------" "-----")
gsc_loga ""
gsc_loga "${_hdr}"
gsc_loga "${_sep}"

for _file in "${_iostat_files[@]}"; do

    _node=$(basename "${_file}" \
        | sed 's/^node_info_//; s/_[0-9]\{4\}-[A-Z][a-z][a-z]-.*//')

    # Parse iostat -x extended output.
    # Detect column positions from each "Device" header (they repeat per interval).
    # Average all device data lines found across all intervals.
    # Handles both old sysstat (combined "await") and new sysstat (r_await + w_await).
    # Output one TSV line per device: dev rs ws rkb wkb await aqu util
    while IFS=$'\t' read -r _dev _rs _ws _rkb _wkb _await _aqu _util; do
        _label="${_node}/${_dev}"
        gsc_loga "$(printf '%-34s %-7s %-7s %-8s %-8s %-10s %-7s' \
            "${_label}" "${_rs}" "${_ws}" "${_rkb}" "${_wkb}" \
            "${_await}" "${_util}")"

        if _cmp_float "${_util}" "${_UTIL_CRIT}"; then
            ((_err++))
            gsc_loga "CRITICAL: ${_label}: disk utilization ${_util}% — device saturated (>${_UTIL_CRIT}%) — redistribute I/O or add capacity"
        elif _cmp_float "${_util}" "${_UTIL_WARN}"; then
            ((_err++))
            gsc_loga "WARNING: ${_label}: disk utilization ${_util}% approaching saturation (>${_UTIL_WARN}%) — monitor closely"
        fi

        if _cmp_float "${_await}" "${_AWAIT_CRIT}"; then
            ((_err++))
            gsc_loga "CRITICAL: ${_label}: I/O await ${_await}ms — severe latency (>${_AWAIT_CRIT}ms) — check dmesg for errors and verify storage path health"
        elif _cmp_float "${_await}" "${_AWAIT_WARN}"; then
            ((_err++))
            gsc_loga "WARNING: ${_label}: I/O await ${_await}ms elevated (>${_AWAIT_WARN}ms) — check I/O scheduler (mq-deadline/none for SSD/NVMe) and competing workloads"
        fi

        if _cmp_float "${_aqu}" "${_QUEUE_WARN}"; then
            ((_err++))
            gsc_loga "WARNING: ${_label}: avg queue depth ${_aqu} deep (>=${_QUEUE_WARN}) — tune nr_requests or throttle workload"
        fi

    done < <(awk '
        /^Device/ {
            # Re-read column positions on every Device header (one per interval)
            for (i = 1; i <= NF; i++) {
                if ($i == "r/s")             c_rs    = i
                if ($i == "w/s")             c_ws    = i
                if ($i == "rkB/s")           c_rkb   = i
                if ($i == "wkB/s")           c_wkb   = i
                if ($i == "await")           c_await = i
                if ($i == "r_await")         c_ra    = i
                if ($i == "w_await")         c_wa    = i
                if ($i == "aqu-sz"  || \
                    $i == "avgqu-sz")        c_aqu   = i
                if ($i == "%util")           c_util  = i
            }
            in_data = 1
            next
        }
        /^[[:space:]]*$/ || /^avg-cpu/ || /^Linux/ { in_data = 0; next }
        in_data && NF >= 6 && $1 ~ /^[a-zA-Z]/ {
            dev = $1
            cnt[dev]++
            sum_rs[dev]  += (c_rs   ? $c_rs   : 0)
            sum_ws[dev]  += (c_ws   ? $c_ws   : 0)
            sum_rkb[dev] += (c_rkb  ? $c_rkb  : 0)
            sum_wkb[dev] += (c_wkb  ? $c_wkb  : 0)
            if (c_await) {
                sum_aw[dev] += $c_await
            } else if (c_ra && c_wa) {
                sum_aw[dev] += ($c_ra + $c_wa) / 2
            }
            sum_aqu[dev]  += (c_aqu  ? $c_aqu  : 0)
            sum_util[dev] += (c_util ? $c_util : 0)
        }
        END {
            for (dev in cnt) {
                n = cnt[dev]
                printf "%s\t%.1f\t%.1f\t%.0f\t%.0f\t%.1f\t%.1f\t%.1f\n",
                    dev,
                    sum_rs[dev]/n,  sum_ws[dev]/n,
                    sum_rkb[dev]/n, sum_wkb[dev]/n,
                    sum_aw[dev]/n,  sum_aqu[dev]/n,
                    sum_util[dev]/n
            }
        }
    ' "${_file}")

done

gsc_loga ""
if [[ "${_err}" -gt 0 ]]; then
    gsc_loga "Detected ${_err} disk performance issue(s)"
else
    gsc_loga "INFO: All nodes within normal disk performance parameters"
fi

gsc_log_info "Saved results ${_output_file}"
