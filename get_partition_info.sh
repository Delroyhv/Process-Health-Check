#!/usr/bin/env bash
set -euo pipefail

# --------------------------------------------------------------
# get_partition_info.sh
# Search cluster_triage/... for
#   "*partition_info_tool_MDCO_MDGW_DLS_RANGES_PARTITION_DETAILS.out"
# Extract lines between markers:
#   ###### clusterPartitioState #######
#   ###### SEED_NODES #######
# Write results to partition_info.log
# --------------------------------------------------------------

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${_script_dir}/gsc_core.sh"

_outfile="partition_info.log"
_pattern="partition_info_tool_MDCO_MDGW_DLS_RANGES_PARTITION_DETAILS.ou"
_search_dir="cluster_triage"

# Clean log file
gsc_truncate_log "${_outfile}" 2
if [[ ! -d "${_search_dir}" ]]; then
    echo "[ERROR] Directory '${_search_dir}' not found"
    exit 1
fi

echo "[INFO] Searching under ${_search_dir} for *${_pattern}"
echo "[INFO] Writing output to ${_outfile}"

mapfile -t _files < <(find "${_search_dir}" -type f -name "*${_pattern}" | sort)

if [[ ${#_files[@]} -eq 0 ]]; then
    echo "[WARN] No matching files found."
    exit 0
fi

for _f in "${_files[@]}"; do
    echo "[INFO] Processing: ${_f}"

    {
        echo
        echo "========================================================="
        echo "FILE: ${_f}"
        echo "========================================================="

        awk '
            /###### clusterPartitioState #######/ {capture=1; next}
            /###### SEED_NODES #######/ {capture=0; exit}
            capture==1
        ' "${_f}"
    } >> "${_outfile}"

done
echo "[INFO] Done. See ${_outfile}"
