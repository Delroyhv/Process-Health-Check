#!/usr/bin/env bash
#
# get_partition_details.sh
#

# Determine search base:
# 1. First argument if provided
# 2. Else current directory
_search_base="${1:-.}"

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
if [[ -r "${_script_dir}/gsc_core.sh" ]]; then
  . "${_script_dir}/gsc_core.sh"
fi

_file_pattern="*partition_info_tool_MDCO_MDGW_DLS_PARTITION_DETAILS.out"
_file_pattern_ext="*partition_info_tool_MDCO_MDGW_DLS_EXTENDED.out"

# Search for the .out file starting from the search base
_out_file=$(find "${_search_base}" \( -name "${_file_pattern}" -o -name "${_file_pattern_ext}" \) -print -quit 2>/dev/null)

# Fallback: if not found, check if cluster_triage exists in current dir and search there
if [[ -z "${_out_file}" && "${_search_base}" == "." && -d "cluster_triage" ]]; then
    _out_file=$(find "cluster_triage" \( -name "${_file_pattern}" -o -name "${_file_pattern_ext}" \) -print -quit 2>/dev/null)
fi

# Final Fallback: partition_tool_info.log in the search base or current directory
if [[ -z "${_out_file}" ]]; then
    if [[ -f "${_search_base}/partition_tool_info.log" ]]; then
        _out_file="${_search_base}/partition_tool_info.log"
    elif [[ -f "partition_tool_info.log" ]]; then
        _out_file="partition_tool_info.log"
    fi
fi

if [[ ! -f "${_out_file}" ]]; then
    echo "Error: Partition details file not found."
    exit 1
fi

# Define info log path for threshold and growth extraction
_info_log_name="health_report_partitionInfo.log"
if [[ -f "${_search_base}/${_info_log_name}" ]]; then
    _info_log="${_search_base}/${_info_log_name}"
elif [[ -f "${_info_log_name}" ]]; then
    _info_log="${_info_log_name}"
fi

# Extract split threshold from info log if available
_split_threshold=""
_monthly_growth=0
if [[ -n "${_info_log:-}" ]]; then
    _split_threshold=$(grep "Partition split thresholds (largest:" "${_info_log}" 2>/dev/null | sed -n 's/.*largest: \([^)]*\)).*/\1/p' || true)
    # Get last growth line from "Per month:" section
    _monthly_growth=$(grep -A 30 "Per month:" "${_info_log}" 2>/dev/null | grep "[0-9]\{4\}-[0-9]\{2\}:" | tail -n 1 | awk '{print $NF}' || echo 0)
fi

# Check if we should use color (from gsc_core.sh logic)
_use_color=0
if command -v _gsc__use_color >/dev/null 2>&1; then
    if _gsc__use_color; then _use_color=1; fi
fi

check_service_placement() {
    local _services_log_name="hcpcs_services_info.log"
    local _services_log=""
    if [[ -f "${_search_base}/${_services_log_name}" ]]; then
        _services_log="${_search_base}/${_services_log_name}"
    elif [[ -f "${_services_log_name}" ]]; then
        _services_log="${_services_log_name}"
    else
        # Try finding it in cluster_triage or other subdirs
        _services_log=$(find "${_search_base}" -name "${_services_log_name}" -print -quit 2>/dev/null || true)
    fi

    [[ -z "${_services_log}" || ! -f "${_services_log}" ]] && return

    local _master_svc="Service-Deployment"
    local _flagged_svcs=("Metadata-Gateway" "S3-Gateway" "Data-Lifecycle")
    local _c_action=""
    local _c_reset=""
    if [[ "${_use_color}" -eq 1 ]]; then
        _c_action="\033[38;2;37;99;235m"
        _c_reset="\033[0m"
    fi

    # Identify master nodes
    local _master_ips
    _master_ips=$(grep -E '^\[[0-9]+\]' "${_services_log}" | grep "${_master_svc}" | awk '{print $2}' | tr -d ':' | tr -d '\r')
    [[ -z "${_master_ips}" ]] && return

    local _placement_alerts=""
    for _ip in ${_master_ips}; do
        local _node_line
        _node_line=$(grep -F " ${_ip}: " "${_services_log}" | head -n 1)
        for _svc in "${_flagged_svcs[@]}"; do
            if echo "${_node_line}" | grep -q "${_svc}"; then
                _placement_alerts="${_placement_alerts}\n[ALERT] ${_svc} is co-located on master/control node ${_ip}."
                _placement_alerts="${_placement_alerts}\n${_c_action}[ACTION  ]${_c_reset} Move ${_svc} off master node to reduce control-plane risk."
            fi
        done
    done

    if [[ -n "${_placement_alerts}" ]]; then
        echo -e "\n--- SERVICE PLACEMENT CHECK ---${_placement_alerts}"
    fi
}

_results=$(awk -v st_val="${_split_threshold}" -v use_color="${_use_color}" -v growth="${_monthly_growth}" '
BEGIN {
    in_s1 = 0; in_s2 = 0; in_cp = 0; in_lc = 0
    t_w = 1000; t_d = 1500; t_c = 2000
    m1 = "###### partitionMap Metadata-Coordination #######"
    m2 = "###### partitionState bad partitions analysis #######"
    node_idx = 0
    total_l = 0
    max_count = 0
    # Color codes
    C_ACTION = "\033[38;2;37;99;235m"
    C_GOOD   = "\033[32m"
    C_WARN   = "\033[33m"
    C_DANGER = "\033[31m"
    C_CRIT   = "\033[1;101;97m"
    C_RESET  = "\033[0m"

    print "================================================"
    print "Partition per node thresholds:"
    if (use_color == 1) {
        printf "  15-999    : [%sgood%s]\n", C_GOOD, C_RESET
        printf "  1000-1499 : [%sWARNING%s]\n", C_WARN, C_RESET
        printf "  1500-1999 : [%sDANGER%s]\n", C_DANGER, C_RESET
        printf "  >= 2000   : [%sCRITICAL%s]\n", C_CRIT, C_RESET
    } else {
        print "  15-999    : [good]"
        print "  1000-1499 : [WARNING]"
        print "  1500-1999 : [DANGER]"
        print "  >= 2000   : [CRITICAL]"
    }
    print "================================================\n"
}

# Section detection
$0 ~ m1 { in_s1 = 1; in_s2 = 0; print $0; next }
$0 ~ m2 { in_s1 = 0; in_s2 = 1; print "\n" $0; next }
/SEED_NODES/ || /internalConfig/ || /\[INFO\]/ { in_s1 = 0; in_s2 = 0; next }

# Section 1 processing
in_s1 {
    if ($0 ~ /^##/) next

    if ($0 ~ /Count of partition copies \/ node, instance:/) {
        in_cp = 1; print $0; next
    }

    if (in_cp) {
        if ($0 ~ /^[[:space:]]*$/) { in_cp = 0; print ""; next }
        if ($0 ~ /Node_IP:/) {
            n = split($0, a); cnt = a[1] + 0
            if (cnt > max_count) max_count = cnt
            st = "good"
            c_lvl = C_GOOD
            if (cnt > t_c) { st = "CRITICAL"; c_lvl = C_CRIT }
            else if (cnt > t_d) { st = "DANGER"; c_lvl = C_DANGER }
            else if (cnt > t_w) { st = "WARNING"; c_lvl = C_WARN }
            
            for(i=1; i<=n; i++) {
                if(a[i] == "Node_IP:") {
                    ip = a[i+1]; sub(/:[0-9]+,/, "", ip); sub(/,/, "", ip)
                    if (use_color == 1) {
                        printf "  %d %s [%s%s%s]\n", cnt, ip, c_lvl, st, C_RESET
                    } else {
                        printf "  %d %s [%s]\n", cnt, ip, st
                    }
                    break
                }
            }
        }
        next
    }

    if ($0 ~ /Leadercount \/ node, instance:/ || $0 ~ /number_of_leaders MDGW_IP:/) {
        in_lc = 1; print "number_of_leader IP"; next
    }

    if (in_lc) {
        if ($0 ~ /^[[:space:]]*$/) {
            if (node_idx > 0) {
                avg = total_l / node_idx
                for (i=0; i<node_idx; i++) {
                    diff = leaders[i] - avg
                    if (diff < 0) diff = -diff
                    if (diff > (0.1 * avg)) {
                        printf "WARNING: Node %s leadership imbalance (%d) deviates >10%% from avg %.1f — indicates Metadata Coordination Service (MDCO) may not be working correctly\n", nodes[i], leaders[i], avg
                    }
                }
            }
            in_lc = 0; print ""; next
        }
        if ($0 ~ /Node_IP:/ || $0 ~ /MDGW_IP:/) {
            n = split($0, a); cnt = a[1] + 0
            for(i=1; i<=n; i++) {
                if(a[i] == "Node_IP:" || a[i] == "MDGW_IP:") {
                    ip = a[i+1]; sub(/:[0-9]+,/, "", ip); sub(/,/, "", ip)
                    print "  " cnt " " ip
                    nodes[node_idx] = ip; leaders[node_idx] = cnt
                    total_l += cnt; node_idx++
                    break
                }
            }
        }
        next
    }

    if ($0 ~ /Count of partitions:/) {
        split($0, a, ":")
        total_partitions = a[2] + 0
        print $0; next
    }
    if ($0 ~ /Count of copies per partition:/) { print $0; next }
    if ($0 ~ /partitions have [0-9]+ copies/) { print $0; next }
}

# Section 2 processing
in_s2 {
    if ($0 ~ /^##/) next
    if ($0 ~ /^[[:space:]]*$/) next
    print "  " $0
}

END {
    label = "[ACTION  ]"
    if (use_color == 1) { label = C_ACTION label C_RESET }

    if (max_count > 1500 && (st_val == "1G" || st_val == "1Gi")) {
        print "\n[ALERT] High partition count (" max_count ") detected with " st_val " split threshold."
        print label " Please open an ASPSUS JIRA to increase the partition split size."
    }

    if (total_partitions > 0) {
        # Calculation: (total_partitions * 3) / 900, rounded up
        # Plus 1 node for monthly growth/headroom
        base_nodes = (total_partitions * 3) / 900
        # Round up manually in awk
        if (base_nodes == int(base_nodes)) ceil_nodes = base_nodes
        else ceil_nodes = int(base_nodes) + 1
        
        recommended_nodes = ceil_nodes + 1
        
        print "\n[INFO   ] Cluster Expansion Sizing:"
        print "  Current Total Partitions: " total_partitions
        print "  Projected Monthly Growth: " growth " splits/month"
        print "  Baseline nodes required:  " ceil_nodes " (based on 900 per-node limit)"
        print label " Expand cluster to " recommended_nodes " Metadata-Gateway nodes to support growth and threshold increase."
    }
}
' "${_out_file}")

echo "${_results}"
check_service_placement
