#!/usr/bin/env bash
#
# ========================================================================
# Copyright (c) by Hitachi Vantara, 2024. All rights reserved.
# ========================================================================
#
# Parse collected top batch output files (top -b -d1 -n30) from cluster
# nodes. Produces a per-node summary of load average, CPU utilisation,
# memory, swap, and task state. Flags nodes exceeding health thresholds.
#
# CPU values are averaged across all 30 iterations for reliability.
# Load average, memory, swap, and task counts are taken from the last
# iteration as the most current snapshot.
#
# Thresholds:
#   Load avg (1min) > 20  : WARNING   — approaching CPU saturation
#   Load avg (1min) > 40  : CRITICAL  — CPU saturated
#   CPU idle < 20%        : WARNING   — high CPU utilisation
#   CPU idle < 10%        : CRITICAL  — CPU critically high
#   CPU iowait > 10%      : WARNING   — disk I/O bottleneck
#   CPU iowait > 20%      : CRITICAL  — severe I/O bottleneck
#   Memory used > 80%     : WARNING   — memory pressure
#   Memory used > 90%     : CRITICAL  — critical memory pressure
#   Swap used > 0         : WARNING   — swap activity detected
#   Zombie tasks > 0      : WARNING   — zombie processes present
#
# References:
#   https://man7.org/linux/man-pages/man1/top.1.html
#     top man page: batch mode (-b), fields (us/sy/id/wa/st), load average,
#     task states (R/S/D/T/Z), memory (total/free/used/buff/cache/avail)
#   https://www.geeksforgeeks.org/linux-unix/top-command-in-linux-with-examples/
#     top usage guide: -b batch, -n iterations, -d delay, output field meanings
#

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${_script_dir}/gsc_core.sh"

_default_output_file="health_report_top.log"
_default_top_log="top.log"
_log_dir="."
_output_file="${_default_output_file}"
_top_log="${_default_top_log}"
_err=0

# Thresholds (can override via environment)
_LOAD_WARN=${TOP_LOAD_WARN:-20}
_LOAD_CRIT=${TOP_LOAD_CRIT:-40}
_IDLE_WARN=${TOP_IDLE_WARN:-20}
_IDLE_CRIT=${TOP_IDLE_CRIT:-10}
_WAIT_WARN=${TOP_WAIT_WARN:-10}
_WAIT_CRIT=${TOP_WAIT_CRIT:-20}
_MEM_WARN=${TOP_MEM_WARN:-80}
_MEM_CRIT=${TOP_MEM_CRIT:-90}

usage() {
    local _this_filename
    _this_filename=$(basename "$0")
    echo "\
Parse top batch output across all cluster nodes.

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

############################

getOptions "$@"

gsc_log_info "== CHECKING TOP PERFORMANCE SNAPSHOT =="

gsc_rotate_log "${_output_file}"
: > "${_top_log}"

mapfile -t _all_top_files < <(find "${_log_dir}" -name '*top-b-d1-n30.out' \
    ! -name '*.err' 2>/dev/null | sort)

if [[ "${#_all_top_files[@]}" -eq 0 ]]; then
    gsc_loga "WARNING: No top batch files found in ${_log_dir}"
    exit 0
fi

# Group by node and pick newest
declare -A _latest_files
for _f in "${_all_top_files[@]}"; do
    _fname=$(basename "${_f}")
    _node=$(echo "${_fname}" | sed 's/^node_info_//; s/_[0-9]\{4\}-[A-Z][a-z][a-z]-.*//')
    _ts=$(echo "${_fname}" | grep -o '[0-9]\{4\}-[A-Z][a-z][a-z]-[0-9]\{2\}_[0-9]\{2\}-[0-9]\{2\}-[0-9]\{2\}')
    
    if [[ -z "${_latest_files[${_node}]:-}" ]]; then
        _latest_files["${_node}"]="${_f}"
    else
        _old_f=$(basename "${_latest_files[${_node}]}")
        _old_ts=$(echo "${_old_f}" | grep -o '[0-9]\{4\}-[A-Z][a-z][a-z]-[0-9]\{2\}_[0-9]\{2\}-[0-9]\{2\}-[0-9]\{2\}')
        if [[ "${_ts}" > "${_old_ts}" ]]; then
            _latest_files["${_node}"]="${_f}"
        fi
    fi
done

mapfile -t _top_files < <(printf '%s\n' "${_latest_files[@]}" | sort)

gsc_log_info "Found ${#_all_top_files[@]} top file(s); analyzing newest for each of the ${#_top_files[@]} unique node(s)"

# Print summary table header
_hdr=$(printf '%-36s %-6s %-14s %-6s %-6s %-6s %-6s %-8s %-8s %-6s %-5s' \
    "Node" "Up(d)" "Load(1m/5m/15m)" "us%" "sy%" "id%" "wa%" "Mem%" "Swap(M)" "Tasks" "Zombie")
_sep=$(printf '%-36s %-6s %-14s %-6s %-6s %-6s %-6s %-8s %-8s %-6s %-5s' \
    "----" "-----" "---------------" "---" "---" "---" "---" "----" "-------" "-----" "------")
gsc_loga ""
gsc_loga "${_hdr}"
gsc_loga "${_sep}"

for _file in "${_top_files[@]}"; do

    _node=$(basename "${_file}" \
        | sed 's/^node_info_//; s/_[0-9]\{4\}-[A-Z][a-z][a-z]-.*//')

    # Append raw content to top.log
    {
        printf '=== %s ===\n' "${_node}"
        cat "${_file}"
        printf '\n'
    } >> "${_top_log}"

    # Parse all iterations with a single awk pass
    # Extracts: uptime days, last load avg, avg cpu fields, last mem/swap/tasks
    read -r _updays _load1 _load5 _load15 \
             _avg_us _avg_sy _avg_id _avg_wa \
             _mem_total _mem_used \
             _swap_used \
             _tasks _zombies \
        < <(awk '
        /^top -/ {
            # uptime: "up N days" or "up N:MM" or "up N min"
            if ($0 ~ /up [0-9]+ day/) {
                for(i=1;i<=NF;i++) if($i=="day"||$i=="days") {updays=$(i-1); break}
            } else updays=0
            # load averages (last 3 numbers before end of line)
            n=split($0,f,",")
            load15=f[n]+0; gsub(/[^0-9.]/,"",load15)
            load5=f[n-1]+0; gsub(/[^0-9.]/,"",load5)
            # load1 is between "load average:" and first comma
            idx=index($0,"load average: ")
            if(idx){
                s=substr($0,idx+14)
                split(s,g,",")
                load1=g[1]+0
            }
        }
        /^%Cpu/ {
            # parse each tagged field
            n=split($0,f,",")
            for(i=1;i<=n;i++){
                v=f[i]; gsub(/[^0-9.a-z]/,"",v)
                if(v~/us$/) { gsub(/us/,"",v); sum_us+=v; cnt_us++ }
                if(v~/sy$/) { gsub(/sy/,"",v); sum_sy+=v; cnt_sy++ }
                if(v~/id$/) { gsub(/id/,"",v); sum_id+=v; cnt_id++ }
                if(v~/wa$/) { gsub(/wa/,"",v); sum_wa+=v; cnt_wa++ }
            }
        }
        /^MiB Mem/ {
            for(i=1;i<=NF;i++){
                if($i=="total") mem_total=$(i-1)+0
                if($i=="used") mem_used=$(i-1)+0
            }
        }
        /^MiB Swap/ {
            for(i=1;i<=NF;i++) if($i=="used") swap_used=$(i-1)+0
        }
        /^Tasks:/ {
            for(i=1;i<=NF;i++){
                if($i=="total") tasks=$(i-1)+0
                if($i=="zombie") zombies=$(i-1)+0
            }
        }
        END {
            avg_us = (cnt_us>0) ? sum_us/cnt_us : 0
            avg_sy = (cnt_sy>0) ? sum_sy/cnt_sy : 0
            avg_id = (cnt_id>0) ? sum_id/cnt_id : 0
            avg_wa = (cnt_wa>0) ? sum_wa/cnt_wa : 0
            mem_pct = (mem_total>0) ? (mem_used/mem_total)*100 : 0
            printf "%s %s %s %s %.1f %.1f %.1f %.1f %.1f %.1f %.1f %.0f %.0f\n",
                updays, load1, load5, load15,
                avg_us, avg_sy, avg_id, avg_wa,
                mem_pct, mem_total, swap_used,
                tasks, zombies
        }
        ' "${_file}")

    _mem_pct="${_avg_id}"   # reuse slot — mem_pct is field 9
    # Reparse cleanly (awk printed: updays load1 load5 load15 us sy id wa mem_pct mem_total swap tasks zombies)
    read -r _updays _load1 _load5 _load15 \
             _avg_us _avg_sy _avg_id _avg_wa \
             _mem_pct _mem_total _swap_used \
             _tasks _zombies \
        < <(awk '
        /^top -/ {
            if ($0 ~ /up [0-9]+ day/) {
                for(i=1;i<=NF;i++) if($i=="day"||$i=="days") {updays=$(i-1); break}
            } else updays=0
            idx=index($0,"load average: ")
            if(idx){
                s=substr($0,idx+14)
                split(s,g,",")
                load1=g[1]+0; load5=g[2]+0; load15=g[3]+0
            }
        }
        /^%Cpu/ {
            n=split($0,f,",")
            for(i=1;i<=n;i++){
                v=f[i]; gsub(/[^0-9.a-z]/,"",v)
                if(v~/us$/) { gsub(/us/,"",v); sum_us+=v; cnt++ }
                if(v~/sy$/) { gsub(/sy/,"",v); sum_sy+=v }
                if(v~/id$/) { gsub(/id/,"",v); sum_id+=v }
                if(v~/wa$/) { gsub(/wa/,"",v); sum_wa+=v }
            }
        }
        /^MiB Mem/ {
            for(i=1;i<=NF;i++){
                if($i=="total") mem_total=$(i-1)+0
                if($i=="used") mem_used=$(i-1)+0
            }
        }
        /^MiB Swap/ { for(i=1;i<=NF;i++) if($i=="used") swap_used=$(i-1)+0 }
        /^Tasks:/   {
            for(i=1;i<=NF;i++){
                if($i=="total") tasks=$(i-1)+0
                if($i=="zombie") zombies=$(i-1)+0
            }
        }
        END {
            n = (cnt>0) ? cnt : 1
            mem_pct = (mem_total>0) ? (mem_used/mem_total)*100 : 0
            printf "%s %.2f %.2f %.2f %.1f %.1f %.1f %.1f %.1f %.0f %.0f %d %d\n",
                updays,
                load1, load5, load15,
                sum_us/n, sum_sy/n, sum_id/n, sum_wa/n,
                mem_pct, mem_total, swap_used,
                tasks, zombies
        }
        ' "${_file}")

    _load_str="${_load1}/${_load5}/${_load15}"
    _swap_mb=$(printf '%.0f' "${_swap_used}")

    gsc_loga "$(printf '%-36s %-6s %-14s %-6s %-6s %-6s %-6s %-8s %-8s %-6s %-5s' \
        "${_node}" "${_updays}" "${_load_str}" \
        "${_avg_us}" "${_avg_sy}" "${_avg_id}" "${_avg_wa}" \
        "${_mem_pct}%" "${_swap_mb}" \
        "${_tasks}" "${_zombies}")"

    # Threshold checks
    _node_issues=0

    # Ensure we have valid data before comparing
    if [[ -z "${_load1}" || -z "${_avg_id}" || -z "${_avg_wa}" || -z "${_mem_pct}" || -z "${_swap_used}" ]]; then
        gsc_log_error "ERROR: ${_node}: failed to extract performance metrics from top output"
        continue
    fi

    # Load average (1-minute) — integer compare via awk
    if awk "BEGIN{exit !( ${_load1} > ${_LOAD_CRIT} )}"; then
        ((_node_issues++)); ((_err++))
        gsc_loga "CRITICAL: ${_node}: load average ${_load1} exceeds critical threshold (>${_LOAD_CRIT}) — CPU saturated"
    elif awk "BEGIN{exit !( ${_load1} > ${_LOAD_WARN} )}"; then
        ((_node_issues++)); ((_err++))
        gsc_loga "WARNING: ${_node}: load average ${_load1} exceeds warning threshold (>${_LOAD_WARN})"
    fi

    # CPU idle — WARNING/CRITICAL for low idle
    if awk "BEGIN{exit !( ${_avg_id} < ${_IDLE_CRIT} )}"; then
        ((_node_issues++)); ((_err++))
        gsc_loga "CRITICAL: ${_node}: CPU idle ${_avg_id}% below critical threshold (<${_IDLE_CRIT}%) — CPU critically high"
    elif awk "BEGIN{exit !( ${_avg_id} < ${_IDLE_WARN} )}"; then
        ((_node_issues++)); ((_err++))
        gsc_loga "WARNING: ${_node}: CPU idle ${_avg_id}% below warning threshold (<${_IDLE_WARN}%)"
    fi

    # I/O wait
    if awk "BEGIN{exit !( ${_avg_wa} > ${_WAIT_CRIT} )}"; then
        ((_node_issues++)); ((_err++))
        gsc_loga "CRITICAL: ${_node}: CPU iowait ${_avg_wa}% exceeds critical threshold (>${_WAIT_CRIT}%) — severe disk I/O bottleneck"
    elif awk "BEGIN{exit !( ${_avg_wa} > ${_WAIT_WARN} )}"; then
        ((_node_issues++)); ((_err++))
        gsc_loga "WARNING: ${_node}: CPU iowait ${_avg_wa}% exceeds warning threshold (>${_WAIT_WARN}%) — disk I/O bottleneck"
    fi

    # Memory used %
    if awk "BEGIN{exit !( ${_mem_pct} > ${_MEM_CRIT} )}"; then
        ((_node_issues++)); ((_err++))
        gsc_loga "CRITICAL: ${_node}: memory used ${_mem_pct}% exceeds critical threshold (>${_MEM_CRIT}%)"
    elif awk "BEGIN{exit !( ${_mem_pct} > ${_MEM_WARN} )}"; then
        ((_node_issues++)); ((_err++))
        gsc_loga "WARNING: ${_node}: memory used ${_mem_pct}% exceeds warning threshold (>${_MEM_WARN}%)"
    fi

    # Swap usage
    if awk "BEGIN{exit !( ${_swap_used} > 0 )}"; then
        ((_node_issues++)); ((_err++))
        gsc_loga "WARNING: ${_node}: swap in use (${_swap_mb} MiB) — memory pressure may cause performance degradation"
    fi

    # Zombie processes
    if [[ "${_zombies}" -gt 0 ]]; then
        ((_node_issues++)); ((_err++))
        gsc_loga "WARNING: ${_node}: ${_zombies} zombie process(es) — parent process not reaping children"
    fi

done

gsc_loga ""
gsc_loga "INFO: Full top output saved to ${_top_log}"

if [[ "${_err}" -gt 0 ]]; then
    gsc_loga "Detected ${_err} issue(s)"
else
    gsc_loga "INFO: All nodes within normal performance parameters"
fi

gsc_log_info "Saved results ${_output_file}"
