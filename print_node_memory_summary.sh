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
#     https://access.redhat/com/solutions/406773
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
        node=$(echo "$fname" | sed -E 's/node_info_([^_]+)_.*_systeminfo_lsmem.out/\1/')
        latest_lsmem["$node"]="$f"
    done

    # Collect total memory for each node, and counts
    declare -A node_memory_total
    local total_nodes=0
    local total_memory_sum=0 # in KB
    local total_memory_display="0G"

    gsc_log_info "Node-level memory details (from lsmem):"
    for node in "${!latest_lsmem[@]}"; do
        lsmem_out=$(cat "${latest_lsmem[$node]}")
        mem_total_raw=$(echo "$lsmem_out" | awk '/Total online memory:/{print $4 $5}') # Get "256G"
        mem_total_kb=$(gsc_to_kb "${mem_total_raw}") # Convert to KB
        
        if [[ -n "$mem_total_kb" && "$mem_total_kb" -gt 0 ]]; then
            node_memory_total["$node"]="${mem_total_kb}"
            ((total_memory_sum+=mem_total_kb))
        else
            node_memory_total["$node"]="N/A"
        fi
        gsc_log_info "  - Node $node: Total memory ${mem_total_raw} (${mem_total_kb}KB)"
        ((total_nodes++))
    done

    # Convert total_memory_sum from KB to GB for display
    if (( total_memory_sum > 0 )); then
        total_memory_display="$(gsc_pretty_bytes "$((total_memory_sum * 1024))")" # Convert KB to Bytes for gsc_pretty_bytes
    fi

    gsc_log_info "Total node count: ${total_nodes}"
    gsc_log_info "Total memory: ${total_memory_display}"

    # Group nodes by identical total memory
    declare -A memory_groups
    for mem in "${!node_memory_total[@]}"; do
        nodes="${memory_groups[$mem]}"
        count=$(echo "$nodes" | wc -w)
        gsc_log_info "  - ${count} node(s) with ${mem}KB (${gsc_pretty_bytes "$((mem * 1024))"}) RAM: ${nodes}"
    done

    # ── Section 2: Runtime memory pressure (free) ────────────────────────────────

    # Find all free outputs
    mapfile -t all_free_files < <(find . -name "*free*.out" 2>/dev/null | sort)

    if [[ ${#all_free_files[@]} -eq 0 ]]; then
        gsc_log_warn "No free(1) output files (*free*.out) found — skipping runtime memory pressure check"
        return
    fi

    # Group by node and pick newest
    declare -A latest_free
    for f in "${all_free_files[@]}"; do
        fname=$(basename "$f")
        node=$(echo "$fname" | sed -E 's/node_info_([^_]+)_.*_free.*.out/\1/')
        latest_free["$node"]="$f"
    done

    gsc_log_info "Runtime memory pressure (from free):"
    for node in "${!latest_free[@]}"; do
        free_out=$(cat "${latest_free[$node]}")
        total_mem_kb=0
        available_mem_kb=0
        total_swap_kb=0
        used_swap_kb=0

        # Parse free output, handling different units
        # Try -h format first for robust parsing
        if echo "$free_out" | grep -q "Mem:"; then
            # Format like: Mem: 100G 50G 40G 10G 5G 10G
            # Available: line 2, col 7
            # Swap: line 3, col 2, col 3
            # Use gsc_to_kb to convert values like 10G, 50M to KB
            total_mem_kb=$(echo "$free_out" | awk '/Mem:/{print $2}' | gsc_to_kb || echo 0)
            available_mem_kb=$(echo "$free_out" | awk '/Mem:/{print $7}' | gsc_to_kb || echo 0)
            total_swap_kb=$(echo "$free_out" | awk '/Swap:/{print $2}' | gsc_to_kb || echo 0)
            used_swap_kb=$(echo "$free_out" | awk '/Swap:/{print $3}' | gsc_to_kb || echo 0)
        elif echo "$free_out" | grep -q "total"; then
            # Format like: total used free shared buff/cache available
            # Mem:   16G  10G  5.0G 1.0G 1.0G 2.0G
            total_mem_kb=$(echo "$free_out" | awk 'NR==2{print $2}' | gsc_to_kb || echo 0)
            available_mem_kb=$(echo "$free_out" | awk 'NR==2{print $7}' | gsc_to_kb || echo 0)
            total_swap_kb=$(echo "$free_out" | awk 'NR==3{print $2}' | gsc_to_kb || echo 0)
            used_swap_kb=$(echo "$free_out" | awk 'NR==3{print $3}' | gsc_to_kb || echo 0)
        fi

        if (( total_mem_kb == 0 )); then
            gsc_log_warn "  - Node $node: Could not parse free(1) output for memory. Skipping runtime check."
            continue
        fi

        local avail_percent=0
        local swap_used_percent=0
        
        if (( total_mem_kb > 0 )); then
            avail_percent=$(( available_mem_kb * 100 / total_mem_kb ))
        fi
        if (( total_swap_kb > 0 )); then
            swap_used_percent=$(( used_swap_kb * 100 / total_swap_kb ))
        fi

        if (( avail_percent < _MEM_AVAIL_CRIT )); then
            gsc_loga "CRITICAL: $node: available memory ${available_mem_kb}KB (${avail_percent}%) below critical threshold (<${_MEM_AVAIL_CRIT}%)"
            _err=1
        elif (( avail_percent < _MEM_AVAIL_WARN )); then
            gsc_loga "WARNING: $node: available memory ${available_mem_kb}KB (${avail_percent}%) below warning threshold (<${_MEM_AVAIL_WARN}%)"
            _err=1
        fi

        if (( used_swap_kb > 0 )); then
            if (( swap_used_percent > _MEM_SWAP_CRIT )); then
                gsc_loga "CRITICAL: $node: swap ${gsc_pretty_bytes "$((used_swap_kb * 1024))"} in use (${swap_used_percent}% of swap) — severe swap thrashing; performance likely degraded"
                _err=1
            else
                gsc_loga "WARNING: $node: swap ${gsc_pretty_bytes "$((used_swap_kb * 1024))"} in use (${swap_used_percent}% of swap) — memory pressure; latency impact"
                _err=1
            fi
        fi
    done
    gsc_log_success "Saved results health_report_node_memory.log"
}

# Helper to convert human-readable sizes (e.g., 10G, 50M) to KB
gsc_to_kb() {
    local _size="$1"
    local _value _unit

    if [[ "${_size}" =~ ([0-9.]+)([KMGTPEZY]?B?) ]]; then
        _value="${BASH_REMATCH[1]}"
        _unit="${BASH_REMATCH[2]}"
    elif [[ "${_size}" =~ ([0-9.]+) ]]; then # raw number (assume KB if large, MB if small)
        _value="${BASH_REMATCH[1]}"
        if (( $(echo "$_value > 2000000" | bc -l) )); then # Heuristic: if > 2GB (2M KB), assume KB
            _unit="KB"
        else # assume MB
            _unit="MB"
        fi
    fi

    case "${_unit}" in
        "KB"|"K"|"") echo "$_value" ;;
        "MB"|"M") echo "$((_value * 1024))" ;;
        "GB"|"G") echo "$((_value * 1024 * 1024))" ;;
        "TB"|"T") echo "$((_value * 1024 * 1024 * 1024))" ;;
        *) echo "0" ;; # Unknown unit
    esac
}

print_node_memory_summary
