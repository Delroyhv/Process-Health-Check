#!/usr/bin/env bash
# ========================================================================
# Copyright (c) by Hitachi, 2021. All rights reserved.
# ========================================================================
#
# THIS SCRIPT MUST ONLY BE USED BY HITACHI VANTARA PERSONNEL.
#
# Property file format is to list mdgw_uuid to be replaced by node names or IPs
# <node_name_or_ip_address>=<mdgw_uuid>
# For example, using hostnames:
# mynode1=91b8c28d-4551-43b5-b490-9acd304901f8
# mynode2=dfb9bd80-ce21-402e-b1bc-7fc07353d52b
# mynode3=4d379461-d4af-48ec-9750-8c980c24577a
# or instead using ip addresses:
# 172.18.10.47=91b8c28d-4551-43b5-b490-9acd304901f8
# 172.18.10.47=dfb9bd80-ce21-402e-b1bc-7fc07353d52b
# 172.18.10.48=4d379461-d4af-48ec-9750-8c980c24577a
#

_tool_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${_tool_dir}/gsc_core.sh"

_debug=0

usage() {
    local _this_filename
    _this_filename=$(basename "$0")

    echo "\
This script parses partition state log file. Default looks for supportLogs/hcpcs_partitions_state.json/log, but if user has their own partitions map file, then use '-f'

Usage: ${_this_filename}
e.g. ${_this_filename} -f partitionState.log

${_this_filename} :
   -d dirName    Optional    Output directory (Defaults to subdirectory, e.g. './_hcpcs.example.com')
   -f fileName   Optional    Input file name for partition state

"
}
set +o posix

####################### INITIALIZATION ###############
#
# Get input options

getOptions "$@"

_cluster_name="*" # cluster name is not needed

_passwd="*"    # password is not needed

# Handle basic options: validate and set default values
handleBasicOptions

# Create directory for output files, if it doesn't exist
createDir

# Check if partition state json/log file exists, if not exit
checkPartitionState() {
    if [ ! -z "$_file_name" ]; then
        echo "$_file_name"
    elif [ -f "supportLogs/hcpcs_partitions_state.json" ]; then
        echo "supportLogs/hcpcs_partitions_state.json"
    elif [ -f "supportLogs/hcpcs_partitions_state.log" ]; then
        echo "supportLogs/hcpcs_partitions_state.log"
    else
        echo "Neither supportLogs/hcpcs_partitions_state.json or supportLogs/hcpcs_partitions_state.log do not exist, please generate by running ./hcpcs_get_partitions_state.sh -c <clusterName>" >&2
        usage
        exit 1
    fi
}

# If user doesn't include partition state json/log, then look for defaults or return error if it doesn't exist
_get_partition_state=$(checkPartitionState)


_log_name="hcpcs_parse_partitions_state"
setLogFile "$_dir_name/${_log_name}"

log2 "# ${_log_name}"

_property_file="$_dir_name/partitionStateProperties.txt"

_entries=$(cat "${_get_partition_state}" | jq -r '.[] | "\(.partitionId) \(.keySpaceId) \(.partitionSize) \(.isLeader) \(.isLeaderAvailable) \(.nodes[0]) \(.nodes[1]) \(.nodes[2]) \(.nodes[3])"' | sort | uniq | sed -e "s/null//")

# if property file is provided and exists
# then replace UUIDs with node's IPs or names
if [[ ! -z "${_property_file}" ]] && [ -f "${_property_file}" ]; then
    _ii=0
    while read -r _line; do
        ((_ii++)) # counter
        IFS='=' read -ra _node <<< "$_line"

        # skip if it's a comment line (starts with # or empty)
        [[ ${_node[0]} =~ ^#.* ]] && continue
        [ "${_node[0]}" = "" ] && continue
        _node_ip="${_node[0]}"   # node ip or name from the property file
        _node_uuid="${_node[1]}" # mdgw-uuid from the property file
        # replace UUIDs with node's IPs or names
        _entries=$(echo "$_entries" | sed "s/${_node_uuid}/${_node_ip}/g")
    done < "${_property_file}"
    gsc_log_info "Used ${_property_file} to replace UUIDs."
else
    gsc_log_info "INFO: Specify a property file to replace UUIDs by host names or IP addresses."
fi

log "${_entries}"
gsc_log_info "Log file ${_dir_name}/${_log_name}.log was generated"
