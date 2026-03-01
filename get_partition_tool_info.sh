#!/usr/bin/env bash
set -euo pipefail

# --------------------------------------------------------------
# get_partition_tool_info.sh
# Search cluster_triage/... for
#   "*partition_info_tool_MDCO_MDGW_DLS_EXTENDED.out"
# Extract lines between markers:
#   ###### clusterPartitioState #######
#   ###### SEED_NODES #######
# Write results to partition_tool_info.log
# Uses centralized logging via gsc_core.sh
# --------------------------------------------------------------

# Resolve script directory and source unified library
_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${_script_dir}/gsc_core.sh"

_outfile="partition_tool_info.log"
_pattern="*_MDCO_MDGW_DLS_*.out"
_search_dir="cluster_triage"

# Start with a clean log each run
gsc_truncate_log "${_outfile}" 2
if [[ ! -d "${_search_dir}" ]]; then
    gsc_log_warn "Directory '${_search_dir}' not found; nothing to do."
    echo "[WARN] Directory '${_search_dir}' not found; nothing to do." >> "${_outfile}"
    exit 0
fi

# Find all matching tool output files
mapfile -t _files < <(find "${_search_dir}" -type f -name "*${_pattern}" 2>/dev/null | sort)

if [[ ${#_files[@]} -eq 0 ]]; then
    gsc_log_warn "No files matching '*${_pattern}' under '${_search_dir}'."
    echo "[WARN] No files matching '*${_pattern}' under '${_search_dir}'." >> "${_outfile}"
    exit 0
fi

for _f in "${_files[@]}"; do
    {
        echo
        echo "========================================================="
        echo "FILE: ${_f}"
        echo "========================================================="

        awk '
            /###### clusterPartitioState #######/ {capture=1; next}
            /###### SEED_NODES #######/         {capture=0; exit}
            capture==1
        ' "${_f}"
    } >> "${_outfile}"
done

gsc_log_info "Wrote partition state blocks from ${#_files[@]} file(s) into ${_outfile}"
echo "[INFO] Wrote partition state blocks from ${#_files[@]} file(s) into ${_outfile}" >> "${_outfile}"
