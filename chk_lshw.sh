#!/usr/bin/env bash
#
# ========================================================================
# Copyright (c) by Hitachi Vantara, 2024. All rights reserved.
# ========================================================================
#
# Parse lshw hardware inventory files collected from cluster nodes and
# produce a per-node summary table. Warns when hardware differs across
# nodes (mixed CPU models, memory size, or NIC count).
#
# References:
#   https://linux.die.net/man/1/lshw
#     lshw man page: options, output classes (cpu, memory, network, disk)
#   https://www.geeksforgeeks.org/linux-unix/lshw-command-in-linux-with-examples/
#     lshw usage guide: -class, -short, -json, -sanitize options
#

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${_script_dir}/gsc_core.sh"

_default_output_file="health_report_lshw.log"
_default_lshw_log="lshw.log"
_log_dir="."
_output_file="${_default_output_file}"
_lshw_log="${_default_lshw_log}"
_err=0

usage() {
    local _this_filename
    _this_filename=$(basename "$0")
    echo "\
Parse lshw hardware inventory across all cluster nodes.

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

# Extract a single hardware property from an lshw text file.
# Usage: lshw_field <file> <awk_pattern>
# Each call runs one awk pass; keeps the main loop readable.
_lshw_get() {
    local _file="$1" _prog="$2"
    awk "${_prog}" "${_file}" 2>/dev/null
}

############################

getOptions "$@"

gsc_log_info "== CHECKING LSHW HARDWARE INVENTORY =="

gsc_rotate_log "${_output_file}"
: > "${_lshw_log}"

mapfile -t _all_lshw_files < <(find "${_log_dir}" -name '*lshw.out' \
    ! -name '*.err' 2>/dev/null | sort)

if [[ "${#_all_lshw_files[@]}" -eq 0 ]]; then
    gsc_loga "WARNING: No lshw files found in ${_log_dir}"
    exit 0
fi

# Group by node and pick newest
declare -A _latest_files
for _f in "${_all_lshw_files[@]}"; do
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

mapfile -t _lshw_files < <(printf '%s\n' "${_latest_files[@]}" | sort)

gsc_log_info "Found ${#_all_lshw_files[@]} lshw file(s); analyzing newest for each of the ${#_lshw_files[@]} unique node(s)"

# Collect per-node data into arrays for cross-node comparison
declare -a _nodes
declare -A _nd_product _nd_cpu _nd_cpucount _nd_mem _nd_dimm_pop _nd_dimm_empty
declare -A _nd_nics _nd_disk

for _file in "${_lshw_files[@]}"; do

    _node=$(basename "${_file}" \
        | sed 's/^node_info_//; s/_[0-9]\{4\}-[A-Z][a-z][a-z]-.*//')
    _nodes+=("${_node}")

    # Log full raw lshw content for this node
    {
        printf '=== %s ===\n' "${_node}"
        cat "${_file}"
        printf '\n'
    } >> "${_lshw_log}"

    # System product (first product: line = chassis/server model)
    _nd_product["${_node}"]=$(awk '/product:/ && !found { gsub(/^[[:space:]]*product: /,""); found=1; print }' "${_file}")

    # CPU: model from first Xeon/EPYC/Core product line; count of sockets
    _nd_cpu["${_node}"]=$(awk '/product:.*[Xx]eon|product:.*EPYC|product:.*Core i/ && !found \
        { gsub(/^[[:space:]]*product: /,""); found=1; print }' "${_file}")
    _nd_cpucount["${_node}"]=$(grep -c '\*-cpu:' "${_file}" 2>/dev/null || echo 0)

    # Memory: total size from System Memory block; populated and empty DIMM counts
    _nd_mem["${_node}"]=$(awk '/description: System Memory/{found=1} found && /^[[:space:]]*size:/{gsub(/^[[:space:]]*size: /,""); print; found=0}' "${_file}")
    _nd_dimm_pop["${_node}"]=$(grep -c 'description: DIMM DDR' "${_file}" 2>/dev/null || echo 0)
    _nd_dimm_empty["${_node}"]=$(grep -c 'product: NO DIMM' "${_file}" 2>/dev/null || echo 0)

    # NICs: count of *-network entries
    _nd_nics["${_node}"]=$(grep -c '\*-network' "${_file}" 2>/dev/null || echo 0)

    # Disk: size from the first *-disk block
    _nd_disk["${_node}"]=$(awk '/\*-disk/{found=1} found && /^[[:space:]]*size:/{gsub(/^[[:space:]]*size: /,""); print; found=0}' "${_file}")

done

# Print summary table header
_hdr=$(printf '%-38s %-12s %-6s %-46s %-8s %-8s %-12s' \
    "Node" "Memory" "NICs" "CPU Model" "Sockets" "DIMMs" "Disk")
_sep=$(printf '%-38s %-12s %-6s %-46s %-8s %-8s %-12s' \
    "----" "------" "----" "---------" "-------" "-----" "----")
gsc_loga ""
gsc_loga "${_hdr}"
gsc_loga "${_sep}"

for _node in "${_nodes[@]}"; do
    _dimm_total=$(( _nd_dimm_pop["${_node}"] + _nd_dimm_empty["${_node}"] ))
    _dimm_info="${_nd_dimm_pop[${_node}]}/${_dimm_total}"
    gsc_loga "$(printf '%-38s %-12s %-6s %-46s %-8s %-8s %-12s' \
        "${_node}" \
        "${_nd_mem[${_node}]:-?}" \
        "${_nd_nics[${_node}]:-?}" \
        "${_nd_cpu[${_node}]:-?}" \
        "${_nd_cpucount[${_node}]:-?}" \
        "${_dimm_info}" \
        "${_nd_disk[${_node}]:-?}")"
done
gsc_loga ""

# Cross-node consistency checks
# Collect unique values for key fields
declare -A _uniq_cpu _uniq_mem _uniq_nics
for _node in "${_nodes[@]}"; do
    _uniq_cpu["${_nd_cpu[${_node}]}"]=1
    _uniq_mem["${_nd_mem[${_node}]}"]=1
    _uniq_nics["${_nd_nics[${_node}]}"]=1
done

if [[ "${#_uniq_cpu[@]}" -gt 1 ]]; then
    ((_err++))
    gsc_loga "WARNING: Mixed CPU models detected across nodes:"
    for _node in "${_nodes[@]}"; do
        gsc_loga "WARNING:   ${_node}: ${_nd_cpu[${_node}]}"
    done
    gsc_loga "NOTICE: ADVICE: Mixed CPU generations cause inconsistent workload performance — nodes"
    gsc_loga "NOTICE:   may execute tasks at different speeds. Standardise to one CPU model across"
    gsc_loga "NOTICE:   all nodes. If a rolling hardware refresh is in progress, complete the"
    gsc_loga "NOTICE:   upgrade before placing the cluster into full production."
fi

if [[ "${#_uniq_mem[@]}" -gt 1 ]]; then
    ((_err++))
    gsc_loga "WARNING: Mixed memory sizes detected across nodes:"
    for _node in "${_nodes[@]}"; do
        gsc_loga "WARNING:   ${_node}: ${_nd_mem[${_node}]}"
    done
    gsc_loga "NOTICE: ADVICE: Unequal memory across nodes affects balanced workload distribution."
    gsc_loga "NOTICE:   Nodes with less RAM may become resource-constrained under equal load."
    gsc_loga "NOTICE:   Align memory capacity across all nodes to ensure consistent headroom."
fi

if [[ "${#_uniq_nics[@]}" -gt 1 ]]; then
    ((_err++))
    gsc_loga "WARNING: Mixed NIC counts detected across nodes:"
    for _node in "${_nodes[@]}"; do
        gsc_loga "WARNING:   ${_node}: ${_nd_nics[${_node}]} NIC(s)"
    done
    gsc_loga "NOTICE: ADVICE: NIC count mismatch indicates different hardware generations or"
    gsc_loga "NOTICE:   configurations. Verify that network bonding, throughput, and redundancy"
    gsc_loga "NOTICE:   are equivalent across all nodes. Additional NICs on newer nodes should"
    gsc_loga "NOTICE:   be configured consistently to avoid asymmetric network capacity."
fi

gsc_loga "INFO: Full lshw output saved to ${_lshw_log}"

if [[ "${_err}" -gt 0 ]]; then
    gsc_loga "Detected ${_err} issue(s)"
else
    gsc_loga "INFO: Hardware inventory consistent across all nodes"
fi

gsc_log_info "Saved results ${_output_file}"
