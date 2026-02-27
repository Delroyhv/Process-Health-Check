#!/usr/bin/env bash
#
# ========================================================================
# Copyright (c) by Hitachi Vantara, 2024. All rights reserved.
# ========================================================================
#
# Check chrony NTP source reachability across all cluster nodes.
#
# For each node's collected chronyc -n sources -v output:
#   - Sources with Reach=377 (octal) are fully reachable (all 8 polls OK)
#   - WARNING when valid sources < 4 (minimum recommended per references below)
#   - ERROR when any source is unreachable (reach=0 or state=?)
#   - ERROR when any source is degraded (reach != 377)
#
# References:
#   https://access.redhat.com/solutions/58025
#     Red Hat: >= 4 NTP sources required; two-server config cannot detect
#     falsetickers. Four is the minimum for adequate selection.
#   https://access.redhat.com/solutions/1259943
#     Red Hat: chrony troubleshooting on RHEL 7/8/9/10; use
#     'chronyc sources' and 'chronyc tracking' to verify sync.
#   http://support.ntp.org/Support/SelectingOffsiteNTPServers (§5.3.3)
#     NTP.org: algorithm requires 2n+1 sources to survive n falsetickers;
#     minimum 4 sources for one-falseticker protection, 5+ preferred.
#

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${_script_dir}/gsc_core.sh"

_default_output_file="health_report_chrony.log"
_default_chronyc_log="chronyc.log"
_log_dir="."
_output_file="${_default_output_file}"
_chronyc_log="${_default_chronyc_log}"
_err=0

usage() {
    local _this_filename
    _this_filename=$(basename "$0")
    echo "\
Check chrony NTP source reachability across all cluster nodes.

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

gsc_log_info "== CHECKING CHRONY NTP SOURCES =="

gsc_rotate_log "${_output_file}"
: > "${_chronyc_log}"

# Find all collected chronyc source files
mapfile -t _all_chrony_files < <(find "${_log_dir}" -name '*chronyc-n_sources-v.out' \
    ! -name '*.err' 2>/dev/null | sort)

if [[ "${#_all_chrony_files[@]}" -eq 0 ]]; then
    gsc_loga "WARNING: No chronyc source files found in ${_log_dir}"
    exit 0
fi

# Group by node and pick the newest file per node
declare -A _latest_files
for _f in "${_all_chrony_files[@]}"; do
    # Extract node and timestamp
    # node_info_cs05_2026-Feb-21_12-58-08_1_...
    _fname=$(basename "${_f}")
    _node=$(echo "${_fname}" | sed 's/^node_info_//; s/_[0-9]\{4\}-[A-Z][a-z][a-z]-.*//')
    # Use the full timestamp string for lexicographical comparison (sortable format)
    _ts=$(echo "${_fname}" | grep -o '[0-9]\{4\}-[A-Z][a-z][a-z]-[0-9]\{2\}_[0-9]\{2\}-[0-9]\{2\}-[0-9]\{2\}')
    
    if [[ -z "${_latest_files[${_node}]:-}" ]]; then
        _latest_files["${_node}"]="${_f}"
    else
        _old_f=$(basename "${_latest_files[${_node}]}")
        _old_ts=$(echo "${_old_f}" | grep -o '[0-9]\{4\}-[A-Z][a-z][a-z]-[0-9]\{2\}_[0-9]\{2\}-[0-9]\{2\}-[0-9]\{2\}')
        # Simple string compare works because of YYYY-Mon-DD format in these filenames
        if [[ "${_ts}" > "${_old_ts}" ]]; then
            _latest_files["${_node}"]="${_f}"
        fi
    fi
done

mapfile -t _chrony_files < <(printf '%s\n' "${_latest_files[@]}" | sort)

gsc_log_info "Found ${#_all_chrony_files[@]} chronyc source file(s); analyzing newest for each of the ${#_chrony_files[@]} unique node(s)"

_nodes_ok=0
_nodes_warn=0
_nodes_err=0

# Arrays to track nodes with specific issues for consolidated reporting
_nodes_unreachable=()
_nodes_degraded=()
_nodes_none=()
_nodes_insufficient=()
declare -A _pattern_counts

for _file in "${_chrony_files[@]}"; do

    # Extract node name from filename pattern:
    # node_info_<node>_<YYYY-Mon-DD>_<seq>_systeminfo_chronyc-n_sources-v.out
    _node=$(basename "${_file}" \
        | sed 's/^node_info_//; s/_[0-9]\{4\}-[A-Z][a-z][a-z]-.*//')

    # Append raw file content to chronyc.log for full detail
    {
        printf '=== %s ===\n' "${_node}"
        cat "${_file}"
        printf '\n'
    } >> "${_chronyc_log}"

    _total_sources=0
    _valid_sources=0    # reach = 377 (all 8 polls successful)
    _failed_sources=0   # reach = 0 or state = ? (unreachable)
    _degraded_sources=0 # reach != 377 and != 0 (partial reachability)
    _synced_source=""
    _node_issues=0

    # Data lines: column 1 is Mode+State (e.g. ^*, ^+, ^-, ^?, ^x, ^~)
    # Fields: MS  Name/IP  Stratum  Poll  Reach  LastRx  LastSample
    while IFS= read -r _line; do
        _mode="${_line:0:1}"
        [[ "${_mode}" == "^" || "${_mode}" == "=" || "${_mode}" == "#" ]] || continue
        [[ "${_line}" =~ [[:space:]] ]] || continue   # skip malformed lines

        _state="${_line:1:1}"
        _name=$(awk '{print $2}' <<< "${_line}")
        _stratum=$(awk '{print $3}' <<< "${_line}")
        _reach=$(awk '{print $5}' <<< "${_line}")

        ((_total_sources++))

        if [[ "${_state}" == "?" || "${_reach}" == "0" ]]; then
            ((_failed_sources++))
            ((_node_issues++))
            printf 'ERROR: %s: source %s unreachable (state=%s reach=%s)\n' "${_node}" "${_name}" "${_state}" "${_reach}" >> "${_output_file}"
        elif [[ "${_reach}" != "377" ]]; then
            ((_degraded_sources++))
            ((_node_issues++))
            printf 'WARNING: %s: source %s degraded (reach=%s, expected 377)\n' "${_node}" "${_name}" "${_reach}" >> "${_output_file}"
        else
            ((_valid_sources++))
            [[ "${_state}" == "*" ]] && _synced_source="${_name} stratum ${_stratum}"
        fi
    done < "${_file}"

    [[ "${_failed_sources}"   -gt 0 ]] && _nodes_unreachable+=("${_node}")
    [[ "${_degraded_sources}" -gt 0 ]] && _nodes_degraded+=("${_node}")

    # Per-node info summary (goes to log file only)
    _summary="INFO: ${_node}: total=${_total_sources} valid(reach=377)=${_valid_sources}"
    [[ "${_degraded_sources}" -gt 0 ]] && _summary+=" degraded=${_degraded_sources}"
    [[ "${_failed_sources}"   -gt 0 ]] && _summary+=" failed=${_failed_sources}"
    [[ -n "${_synced_source}" ]] && _summary+=" synced-to=${_synced_source}"
    printf '%s\n' "${_summary}" >> "${_output_file}"

    # Minimum source count check (RH #58025, NTP.org §5.3.3: 4 minimum)
    if [[ "${_total_sources}" -eq 0 ]]; then
        printf 'ERROR: %s: no NTP sources found\n' "${_node}" >> "${_output_file}"
        _nodes_none+=("${_node}")
        ((_node_issues++))
    elif [[ "${_valid_sources}" -lt 4 ]]; then
        printf 'WARNING: %s: only %d of %d source(s) fully reachable — minimum 4 required (ref: RH #58025, NTP.org §5.3.3)\n' \
            "${_node}" "${_valid_sources}" "${_total_sources}" >> "${_output_file}"
        
        # Track counts of specific "X of Y" patterns for consolidated reporting
        _key="${_valid_sources} of ${_total_sources}"
        _pattern_counts["${_key}"]=$(( ${_pattern_counts["${_key}"]:-0} + 1 ))
        
        _nodes_insufficient+=("${_node}")
        ((_node_issues++))
    fi

    if [[ "${_node_issues}" -gt 0 ]]; then
        ((_err++))
        if [[ "${_failed_sources}" -gt 0 || "${_total_sources}" -eq 0 ]]; then
            ((_nodes_err++))
        else
            ((_nodes_warn++))
        fi
    else
        ((_nodes_ok++))
    fi

done

# Print consolidated warnings/errors to screen via gsc_loga
if [[ ${#_nodes_none[@]} -gt 0 ]]; then
    gsc_loga "ERROR: ${#_nodes_none[@]} node(s) have NO NTP sources configured"
fi
if [[ ${#_nodes_unreachable[@]} -gt 0 ]]; then
    gsc_loga "ERROR: ${#_nodes_unreachable[@]} node(s) have unreachable NTP sources"
fi
if [[ ${#_nodes_degraded[@]} -gt 0 ]]; then
    gsc_loga "WARNING: ${#_nodes_degraded[@]} node(s) have degraded NTP sources (reach < 377)"
fi

# Consolidated reachable/total patterns
if [[ ${#_pattern_counts[@]} -gt 0 ]]; then
    for _p in "${!_pattern_counts[@]}"; do
        gsc_loga "WARNING: ${_pattern_counts[$_p]} node(s) have only ${_p} source(s) fully reachable — minimum 4 required"
    done
fi

if [[ ${#_nodes_insufficient[@]} -gt 0 ]]; then
    gsc_loga "WARNING: ${#_nodes_insufficient[@]} node(s) in total have insufficient reachable sources — refer to logs for details"
fi

# Final summary
gsc_loga "INFO: Chrony check complete — ${#_chrony_files[@]} node(s): OK=${_nodes_ok} WARN=${_nodes_warn} ERR=${_nodes_err}"
gsc_loga "INFO: Full chronyc output saved to ${_chronyc_log}"

if [[ "${_err}" -gt 0 ]]; then
    gsc_loga "Detected ${_err} issue(s)"
else
    gsc_loga "INFO: All chrony sources healthy"
fi

gsc_log_info "Saved results ${_output_file}"
