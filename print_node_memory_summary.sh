#!/usr/bin/env bash
#
# ========================================================================
# Copyright (c) by Hitachi Vantara, 2024. All rights reserved.
# ========================================================================
#
# Print cluster-wide node memory summary in two sections:
#
#   Section 1 — Hardware capacity (lsmem): groups nodes by total installed
#     memory to surface heterogeneous hardware in the cluster.
#
#   Section 2 — Runtime memory pressure (free): parses collected free(1)
#     output (*free*.out) per node; reports available memory and swap
#     usage; flags nodes under memory pressure.
#
# Memory pressure thresholds (driven by the "available" column of free(1),
# which is the kernel's own estimate of usable memory — see References):
#
#   Available < 20% of total : WARNING  — memory pressure beginning;
#                               kernel reclaiming page cache aggressively;
#                               monitor for OOM events in journal
#   Available < 10% of total : CRITICAL — severe memory pressure;
#                               imminent OOM risk; identify top consumers
#                               with: ps aux --sort=-%mem | head
#   Swap used  > 0           : WARNING  — kernel has exhausted reclaimable
#                               page cache and is paging; all application
#                               I/O latency will increase
#   Swap used  > 10% of total: CRITICAL — significant swap thrashing;
#                               severe performance degradation likely;
#                               add memory or reduce heap allocations
#
# Unit auto-detection (integers without suffix from free -m vs free -k):
#   Values > 2,000,000 with no unit suffix are assumed to be KiB (free -k
#   or plain free); smaller unitless integers are assumed to be MiB
#   (free -m). Values with G/M/K/B suffixes (free -h) are always parsed
#   exactly. This heuristic is valid for nodes with ≤ ~2 TiB RAM.
#
# References:
#   free(1) — util-linux
#     https://man7.org/linux/man-pages/man1/free.1.html
#     "available": estimate of memory for new apps without swapping;
#     accounts for reclaimable page cache and kernel slabs — more
#     accurate than free + buff/cache
#   Red Hat Enterprise Linux 8 — Monitoring memory usage
#     https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/
#     8/html/monitoring_and_managing_system_status_and_performance/
#     assembly_monitoring-memory-usage
#     Rule of thumb: available < 20% → pressure building;
#                    available < 10% → high pressure / imminent OOM
#   Red Hat Knowledgebase — Understanding /proc/meminfo (Article 406773)
#     https://access.redhat.com/solutions/406773
#     MemAvailable reflects the same value as free(1) "available" column
#   Brendan Gregg — USE Method: Memory
#     Utilisation: used / total   Saturation: swap activity, pgscan/s
#     Any non-zero swap usage indicates memory saturation
#   lsmem(8) — util-linux
#     https://man7.org/linux/man-pages/man8/lsmem.8.html
#     "Total online memory": total accessible RAM
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -r "${SCRIPT_DIR}/gsc_core.sh" ]]; then
    # shellcheck disable=SC1090
    . "${SCRIPT_DIR}/gsc_core.sh"
else
    echo "[ERROR] gsc_core.sh not found in ${SCRIPT_DIR}" >&2
    exit 1
fi

_output_file="health_report_node_memory.log"
_err=0

# Thresholds (override via environment variable)
_MEM_AVAIL_WARN=${MEM_AVAIL_WARN:-20}  # available % of total below which → WARNING
_MEM_AVAIL_CRIT=${MEM_AVAIL_CRIT:-10}  # available % of total below which → CRITICAL
_MEM_SWAP_CRIT=${MEM_SWAP_CRIT:-10}    # swap used % of swap total above which → CRITICAL

# ── Section 1: Hardware capacity (lsmem) ────────────────────────────────────

print_node_memory_summary() {
    gsc_log_info "Node operating system and memory summary:"

    # Find all lsmem outputs
    mapfile -t all_lsmem_files < <(find . -name "node_info*systeminfo_lsmem.out" 2>/dev/null | sort)

    if [[ ${#all_lsmem_files[@]} -eq 0 ]]; then
        gsc_log_warn "No node_info*systeminfo_lsmem.out files found; cannot determine node memory."
        return
    fi

    # Group by node and pick newest
    declare -A latest_lsmem
    for f in "${all_lsmem_files[@]}"; do
        fname=$(basename "$f")
        node=$(echo "$fname" | sed 's/^node_info_//; s/_[0-9]\{4\}-[A-Z][a-z][a-z]-.*//')
        ts=$(echo "$fname" | grep -o '[0-9]\{4\}-[A-Z][a-z][a-z]-[0-9]\{2\}_[0-9]\{2\}-[0-9]\{2\}-[0-9]\{2\}')
        
        if [[ -z "${latest_lsmem[$node]:-}" ]]; then
            latest_lsmem["$node"]="$f"
        else
            old_ts=$(basename "${latest_lsmem[$node]}" | grep -o '[0-9]\{4\}-[A-Z][a-z][a-z]-[0-9]\{2\}_[0-9]\{2\}-[0-9]\{2\}-[0-9]\{2\}')
            if [[ "$ts" > "$old_ts" ]]; then
                latest_lsmem["$node"]="$f"
            fi
        fi
    done

    # mem_counts["256G"]=N
    declare -A mem_counts=()

    for node in "${!latest_lsmem[@]}"; do
        f="${latest_lsmem[$node]}"
        # Example line:
        #   Total online memory:     256G
        mem_val="$(awk -F':' '/^Total online memory:/ {gsub(/^[ \t]+/, "", $2); print $2}' "$f" | head -n1)"
        [[ -z "${mem_val}" ]] && continue
        mem_val="$(echo "${mem_val}" | awk '{print $1}')"
        mem_counts["${mem_val}"]=$(( ${mem_counts["${mem_val}"]:-0} + 1 ))
    done

    if [[ ${#mem_counts[@]} -eq 0 ]]; then
        gsc_log_warn "No 'Total online memory' lines found in systeminfo_lsmem.out files."
        return
    fi

    for mem in "${!mem_counts[@]}"; do
        gsc_log_info "${mem_counts[$mem]} nodes ${mem} of memory."
    done
}

# ── Section 2: Runtime memory pressure (free) ───────────────────────────────

print_node_free_memory() {
    mapfile -t all_free_files < <(find . -name '*free*.out' \
        ! -name '*.err' 2>/dev/null | sort)

    if [[ "${#all_free_files[@]}" -eq 0 ]]; then
        gsc_loga "WARNING: No free(1) output files (*free*.out) found — skipping runtime memory pressure check"
        return
    fi

    # Group by node and pick newest
    declare -A latest_free
    for f in "${all_free_files[@]}"; do
        fname=$(basename "$f")
        node=$(echo "$fname" | sed 's/^node_info_//; s/_[0-9]\{4\}-[A-Z][a-z][a-z]-.*//')
        ts=$(echo "$fname" | grep -o '[0-9]\{4\}-[A-Z][a-z][a-z]-[0-9]\{2\}_[0-9]\{2\}-[0-9]\{2\}-[0-9]\{2\}')
        
        if [[ -z "${latest_free[$node]:-}" ]]; then
            latest_free["$node"]="$f"
        else
            old_ts=$(basename "${latest_free[$node]}" | grep -o '[0-9]\{4\}-[A-Z][a-z][a-z]-[0-9]\{2\}_[0-9]\{2\}-[0-9]\{2\}-[0-9]\{2\}')
            if [[ "$ts" > "$old_ts" ]]; then
                latest_free["$node"]="$f"
            fi
        fi
    done

    mapfile -t _free_files < <(printf '%s\n' "${latest_free[@]}" | sort)

    gsc_log_info "Found ${#all_free_files[@]} free(1) files; analyzing newest for each of the ${#_free_files[@]} unique node(s)"

    _hdr=$(printf '%-32s %-8s %-8s %-8s %-7s %-9s' \
        "Node" "Total" "Used" "Avail" "Avail%" "SwapUsed")
    _sep=$(printf '%-32s %-8s %-8s %-8s %-7s %-9s' \
        "----" "-----" "----" "-----" "------" "--------")
    gsc_loga ""
    gsc_loga "── Runtime Memory Pressure ──"
    gsc_loga "${_hdr}"
    gsc_loga "${_sep}"

    for _file in "${_free_files[@]}"; do

        _node=$(basename "${_file}" \
            | sed 's/^node_info_//; s/_[0-9]\{4\}-[A-Z][a-z][a-z]-.*//')

        # Parse free(1) output into MiB integers.
        #
        # to_mb(v): converts a value+optional-unit-suffix to MiB.
        #   G/Gi  → × 1024        M/Mi → × 1 (already MiB)
        #   K/Ki  → ÷ 1024        B    → negligible
        #   no suffix, value > 2 000 000 → assumed KiB (free -k default)
        #   no suffix, value ≤ 2 000 000 → assumed MiB (free -m)
        #
        # Supports: free -m, free -h, free -k (plain free).
        # Mem:  col2=total col3=used col4=free col5=shared col6=buff/cache col7=avail
        # Swap: col2=total col3=used
        read -r _total_mb _used_mb _avail_mb _swap_total_mb _swap_used_mb \
            < <(awk '
            function to_mb(v,    n, u) {
                n = v + 0
                u = v; gsub(/[0-9.]+/, "", u)
                if (u ~ /^[Tt]/) return n * 1024 * 1024
                if (u ~ /^[Gg]/) return n * 1024
                if (u ~ /^[Kk]/) return n / 1024
                if (u ~ /^[Bb]/) return 0
                if (n > 2000000)  return n / 1024   # unitless KiB (free -k)
                return n                             # unitless MiB (free -m)
            }
            /^Mem:/  {
                total_mb = to_mb($2)
                used_mb  = to_mb($3)
                # Column 7 (available) present on util-linux >= 3.3 / RHEL 8+.
                # Fall back to free+buff/cache for older free (RHEL 6/7).
                avail_mb = (NF >= 7) ? to_mb($7) : to_mb($4) + to_mb($6)
            }
            /^Swap:/ {
                swap_total_mb = to_mb($2)
                swap_used_mb  = to_mb($3)
            }
            END {
                printf "%d %d %d %d %d\n",
                    total_mb, used_mb, avail_mb, swap_total_mb, swap_used_mb
            }
        ' "${_file}")

        # Skip unparseable files
        if [[ "${_total_mb:-0}" -eq 0 ]]; then
            ((_err++))
            gsc_loga "WARNING: ${_node}: could not parse free(1) output in ${_file}"
            continue
        fi

        _avail_pct=$(awk "BEGIN{printf \"%d\", ${_avail_mb}/${_total_mb}*100}")
        _total_g=$(awk   "BEGIN{printf \"%.1fG\", ${_total_mb}/1024}")
        _used_g=$(awk    "BEGIN{printf \"%.1fG\", ${_used_mb}/1024}")
        _avail_g=$(awk   "BEGIN{printf \"%.1fG\", ${_avail_mb}/1024}")
        _swap_used_g=$(awk "BEGIN{printf \"%.1fG\", ${_swap_used_mb}/1024}")

        gsc_loga "$(printf '%-32s %-8s %-8s %-8s %-7s %-9s' \
            "${_node}" "${_total_g}" "${_used_g}" "${_avail_g}" \
            "${_avail_pct}%" "${_swap_used_g}")"

        # Available memory checks
        if [[ "${_avail_pct}" -lt "${_MEM_AVAIL_CRIT}" ]]; then
            ((_err++))
            gsc_loga "CRITICAL: ${_node}: available memory ${_avail_pct}% (${_avail_g} of ${_total_g}) — severe memory pressure (<${_MEM_AVAIL_CRIT}%); imminent OOM risk — run: ps aux --sort=-%mem | head -20"
        elif [[ "${_avail_pct}" -lt "${_MEM_AVAIL_WARN}" ]]; then
            ((_err++))
            gsc_loga "WARNING: ${_node}: available memory ${_avail_pct}% (${_avail_g} of ${_total_g}) below threshold (<${_MEM_AVAIL_WARN}%) — kernel reclaiming page cache; monitor journal for OOM events"
        fi

        # Swap usage checks
        if [[ "${_swap_used_mb}" -gt 0 ]]; then
            if [[ "${_swap_total_mb}" -gt 0 ]]; then
                _swap_pct=$(awk "BEGIN{printf \"%d\", ${_swap_used_mb}/${_swap_total_mb}*100}")
            else
                _swap_pct=100
            fi
            if [[ "${_swap_pct}" -ge "${_MEM_SWAP_CRIT}" ]]; then
                ((_err++))
                gsc_loga "CRITICAL: ${_node}: swap ${_swap_used_g} in use (${_swap_pct}% of swap) — memory thrashing; severe latency impact — add RAM or reduce container heap limits"
            else
                ((_err++))
                gsc_loga "WARNING: ${_node}: swap ${_swap_used_g} in use — page cache exhausted; application latency will increase (ref: Gregg USE Method — memory saturation)"
            fi
        fi

    done

    gsc_loga ""
    if [[ "${_err}" -gt 0 ]]; then
        gsc_loga "Detected ${_err} memory pressure issue(s)"
    else
        gsc_loga "INFO: All nodes within normal memory parameters"
    fi
}

############################

gsc_rotate_log "${_output_file}"
print_node_memory_summary
print_node_free_memory
gsc_log_info "Saved results ${_output_file}"
