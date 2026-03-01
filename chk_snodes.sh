#!/usr/bin/env bash
#
# ========================================================================
# Copyright (c) by Hitachi, 2021-2024. All rights reserved.
# ========================================================================
#
# It checks information about S-nodes connected to HCP-CS system.
#
# List of checks
# check storageType HCPS_S3
# check protocol http vs https
# check port 443 vs 80
# check maxConnections
# check state
# check read-only
#
###################################################################

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${_script_dir}/gsc_core.sh"

_debug=0            # debug mode
_verbose="false"    # verbose

_default_output_file="health_report_snodes.log"
_default_input_dir="."
_default_input_short_file="get-config_aspen_storage_component-list.out"

_log_dir=${_default_input_dir}
_output_file=${_default_output_file}
_short_filename=${_default_input_short_file}

_default_max_connections="1024"
_default_port="443"
_default_proto="https"
_default_type="HCPS_S3"

#######
usage() {
    local _this_filename
    _this_filename=$(basename "$0")

    echo "\
This script validates/checks system snodes.

${_this_filename} -d <dir-name> -o <output-file>

${_this_filename} :

   -d <dir-name>                directory with input files

   -o <output_log_file>         output log file (default: ${_default_output_file}
"
}

##############################
#
# Check the input parameters:
#
getOptions() {
    local _opt
    while getopts "d:o:f:vh" _opt; do
        case ${_opt} in
            d)  _log_dir=${OPTARG}
                ;;

            v)  _verbose="true" ; _debug=1
                ;;

            o)  _output_file=${OPTARG}
                ;;

            f)  _short_filename=${OPTARG}
                ;;

            *)  usage
                exit 0
                ;;
        esac
    done
}

#################################################
#
# START
#
getOptions "$@"

if [[ -f ${_output_file} ]]; then
    mv ${_output_file} ${_output_file}.bak
fi

gsc_log_info "== CHECKING STORAGE COMPONENTS CONFIG (S-NODES) =="

_sc_config_file="$(gsc_find_file "${_log_dir}" "${_short_filename}")"

if [[ "${_sc_config_file}" == "" ]]; then
    gsc_log_error "ERROR: CANNOT FIND ${_short_filename} (short file name)"
    exit
fi

if [[ ! -f ${_sc_config_file} ]]; then
    gsc_log_error "ERROR: CANNOT FIND ${_sc_config_file} file"
    exit
fi

# Check if the 1st line is the comment and needs to be removed before processing by jq
_first_line=$(head -n 1 ${_sc_config_file})
if [[ "${_first_line}" == "#"* ]]; then
    _sc_config_json=$(tail -n +2 ${_sc_config_file})
    ((_num_lines=$(wc -l < ${_sc_config_file}) -1))
else
    _sc_config_json=$(cat ${_sc_config_file})
    _num_lines=$(wc -l < ${_sc_config_file})
fi

if [[ "${_sc_config_json}" == "" || "$(gsc_is_json "${_sc_config_json}")" == "false" ]]; then
    gsc_log_error "ERROR: INPUT SC CONFIG FILE: ${_sc_config_file} - NOT EXPECTED FORMAT"
    gsc_log_info "Number of lines: ${_num_lines}"
    gsc_log_info "First line: ${_first_line}"
    gsc_log_debug "${_sc_config_json}"
    exit
fi

_sc_config_json=$(echo "${_sc_config_json}" | jq .)

####
#
# Check if any storage types are NOT S-node
#
_sc_num=$(echo "${_sc_config_json}" | grep -c "storageType")
_snodes_num=$(echo "${_sc_config_json}" | grep "storageType" | grep -c "${_default_type}")

gsc_loga "INFO: Total Storage Components: ${_sc_num}, number of S-nodes: ${_snodes_num}"

if (( _sc_num != _snodes_num )); then
    _sc_types=$(echo "${_sc_config_json}" | jq '.[].storageType')
    ((_num_non_snodes=_sc_num - _snodes_num))
    gsc_loga "WARNING: Detected ${_num_non_snodes} non S-node storage components (not ${_default_type})"
fi

####
# Check if any protocols are NOT https
#
_sc_proto=$(echo "${_sc_config_json}" | grep "https" | grep -c "true")
if (( _sc_num != _sc_proto )); then
    _sc_protos=$(echo "${_sc_config_json}" | jq '.[].storageComponentConfig.https')
    _num_sc_protos=$(echo "${_sc_protos}" | wc -l)
    gsc_loga "WARNING: Detected ${_num_sc_protos} storage components with a non-default protocol (http)"
fi

####
# Check if any ports are NOT 443
#
_sc_port=$(echo "${_sc_config_json}" | grep "port" | grep -c "${_default_port}")
if (( _sc_num != _sc_port )); then
    gsc_log_debug "${_sc_config_json}"
    _sc_ports=$(echo "${_sc_config_json}" | jq '.[].storageComponentConfig.port')
    _num_sc_ports=$(echo "${_sc_ports}" | wc -l)

    gsc_loga "WARNING: Detected ${_num_sc_ports} storage components with non-${_default_port} port"
fi


####
# Check if any maxConnections are NOT default (1024)
#
_sc_max_conn=$(echo "${_sc_config_json}" | grep "maxConnections" | grep -c "${_default_max_connections}")
if (( _sc_num != _sc_max_conn )); then

    _sc_max_conns=$(echo "${_sc_config_json}" | jq '.[].storageComponentConfig.maxConnections')
    _num_sc_max_conns=$(echo "${_sc_max_conns}" | wc -l)

    gsc_loga "WARNING: Detected ${_num_sc_max_conns} storage components with non-default maxConnections (default: ${_default_max_connections})"

    gsc_loga "$(echo "${_sc_config_json}" | jq -r ' .[].storageComponentConfig | " \(.label)\t\t" + "\(.host)\t\t" + "\(.maxConnections)"')"
fi
