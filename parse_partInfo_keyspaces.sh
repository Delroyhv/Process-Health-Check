#!/usr/bin/env bash
#
_dir_name=${1:-"."}
_bucket_file=${2:-"../buckets_names.txt"}

_tool_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${_tool_dir}/gsc_core.sh"

usage() {
    echo "Process all data based on partition map and state in a specified directory
$0 <dir-name> [<buckets_names>]

<dir-name>      - directory to be processed (default is current directory)
<buckets-name>  - file name with buckets-uuids mapping"
}

if [[ "$1" == "-h" ]]; then
    usage
    exit
fi

_failed=0

if [[ -f "${_bucket_file}" ]]; then
    echo "Copy ${_bucket_file} to ${_dir_name}"
    cp "${_bucket_file}" "${_dir_name}"
fi

date

if [[ ! -f "${_dir_name}/supportLogs/hcpcs_partitions_map.log" ]] ; then
    echo "ERROR: cannot find ${_dir_name}/supportLogs/hcpcs_partitions_map.log"
    ((_failed++))
fi

if [[ ! -f "${_dir_name}/supportLogs/hcpcs_partitions_state.log" ]] ; then
    echo "ERROR: cannot find ${_dir_name}/supportLogs/hcpcs_partitions_state.log"
    ((_failed++))
fi

if [[ ! "${_failed}" == "0" ]]; then
    echo "Exiting ..."
    exit
fi

cd "${_dir_name}" || exit 1

echo "# ${_tool_dir}/hcpcs_parse_partitions_map.sh"
"${_tool_dir}/hcpcs_parse_partitions_map.sh"

echo "# ${_tool_dir}/hcpcs_parse_partitions_state.sh"
"${_tool_dir}/hcpcs_parse_partitions_state.sh"

echo "# ${_tool_dir}/parse_map_ranges.sh"
"${_tool_dir}/parse_map_ranges.sh"

echo "# ${_tool_dir}/insert_sizes_1dir.sh partitions_ranges_15.txt"
"${_tool_dir}/insert_sizes_1dir.sh" . partitions_ranges_15.txt

echo "# ${_tool_dir}/insert_sizes_1dir.sh partitions_ranges_40.txt"
"${_tool_dir}/insert_sizes_1dir.sh" . partitions_ranges_40.txt

echo "# ${_tool_dir}/insert_sizes_1dir.sh partitions_ranges_41.txt"
"${_tool_dir}/insert_sizes_1dir.sh" . partitions_ranges_41.txt

echo "# ${_tool_dir}/detect_app_per_bucket.sh"
"${_tool_dir}/detect_app_per_bucket.sh" partitions_ranges_15_size.txt

echo "#### DONE ####"
