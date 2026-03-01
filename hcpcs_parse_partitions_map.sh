#!/usr/bin/env bash
# ========================================================================
# Copyright (c) by Hitachi, 2023. All rights reserved.
# ========================================================================
#
# THIS SCRIPT MUST ONLY BE USED BY HITACHI VANTARA PERSONNEL.
#
# Parse partition map
#

_tool_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${_tool_dir}/gsc_core.sh"
set +o posix

_debug=0

usage() {
    local _this_filename
    _this_filename=$(basename "$0")

    echo "\
This script parses partition map log file.
Default looks for supportLogs/hcpcs_partitions_map.json/log but if user has their own partitions map file, then use the '-f' parameter

Usage: ${_this_filename}
e.g. ${_this_filename} -f partitionFileName.json

${_this_filename} :
   -d dirName    Optional    Output directory (Defaults to subdirectory, e.g. './_hcpcs.example.com')
   -f fileName   Optional    Input file name for partition map

"
}

####################### INITIALIZATION ###############
#
# Get input options
getOptions "$@"

_cluster_name="*"

_passwd="*"    # password is not needed

# Handle basic options: validate and set default values
handleBasicOptions

# Create directory for output files, if it doesn't exist
createDir

###################### CHECK  ####################
# Check if hcpcs_partitions_map.json/log already exists, if not, then ask user to generate it
checkPartitionMap() {
    if [ ! -z "$_file_name" ]; then
        echo "$_file_name"
    elif [ -f "supportLogs/hcpcs_partitions_map.json" ]; then
        echo "supportLogs/hcpcs_partitions_map.json"
    elif [ -f "supportLogs/hcpcs_partitions_map.log" ]; then
        echo "supportLogs/hcpcs_partitions_map.log"
    else
        echo "Neither supportLogs/hcpcs_partitions_map.json or supportLogs/hcpcs_partitions_map.log exist, please generate by running ./hcpcs_get_partitions_map.sh -c <clusterName>" >&2
        usage
        exit 1
    fi
}

# If user doesn't input partition map json/log, then look for defaults or return error if it doesn't exist
_get_partitions_map=$(checkPartitionMap)

###################### LOG INFO ####################
_partition_leader_log="hcpcs_parse_partitions_leader_count"
setLogFile "$_dir_name/${_partition_leader_log}"

log2 "# ${_partition_leader_log}"


_partitions=$(hcpcs_json_body_from_file "$_get_partitions_map" | \
    jq -r '[.[].entryMapping | to_entries[]] | unique_by(.key) | .[].value.nodesLeaderFirst[0].connectionUrl' | \
    grep -v "null" | sed 's/:12500//g' | sort | uniq -c)
_leaders=$(hcpcs_json_body_from_file "$_get_partitions_map" | \
    jq -r '[.[].entryMapping | to_entries[]] | unique_by(.key) | .[].value.nodesLeaderFirst[0].connectionUrl' | \
    grep -v "null" | sed 's/:12500//g' | sort | uniq -c)

loga "Partition Count"
loga "$_partitions"
loga "Leader Count"
loga "$_leaders"


###################### LOG INFO ####################
_partition_map="hcpcs_parse_partitions_map"
setLogFile "$_dir_name/${_partition_map}"

log2 "# ${_partition_map}"

_partition_list=$(hcpcs_json_body_from_file "$_get_partitions_map" | jq -r '.[] | .entryMapping | to_entries[] | .key + " Leader:" + .value.nodesLeaderFirst[0].connectionUrl + ", Followers:" + .value.nodesLeaderFirst[1].connectionUrl + " " + .value.nodesLeaderFirst[2].connectionUrl + " " + .value.nodesLeaderFirst[3].connectionUrl' | sed "s/:12500//g" | sort | uniq)

log "${_partition_list}"

# Generate partitionStateProperties.txt, shows corresponding UUID to its IP address
_property_file="partitionStateProperties.txt"
_nodes_uuids=$(hcpcs_json_body_from_file "$_get_partitions_map" | jq -r '.[] | .entryMapping | to_entries[] | .value.nodesLeaderFirst[] | .connectionUrl + "=" + .nodeId' | sed "s/:12500//g" | sort | uniq)

echo "${_nodes_uuids}" | tee "$_dir_name/${_property_file}" >/dev/null

gsc_log_info "Created $_dir_name/${_partition_leader_log}.log, $_dir_name/${_partition_map}.log and $_dir_name/${_property_file}"
