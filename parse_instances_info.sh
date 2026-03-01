#!/usr/bin/env bash
#
# ========================================================================
# Copyright (c) by Hitachi, 2021-2024. All rights reserved.
# ========================================================================
#
# It parses information about the instances and services running on the HCP for Cloud Scale system.
#

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${_script_dir}/gsc_core.sh"

_default_input_file_shortname="config_foundry_instances.out"
_default_output_file="hcpcs_services_info.log"

_debug=0        # debug mode
_verbose="false"  # verbose

_input_file=""
_dir_name="."
_input_file_shortname="${_default_input_file_shortname}"
_output_file="${_default_output_file}"

_input_json_file=""

################################

usage() {
    local _this_filename
    _this_filename=$(basename "$0")

    echo "\
This script gets a list of nodes for each service and a list of services on each node.

${_this_filename} -f <input-file> -o <output-file> -d <dir-name> -s <input-file-shortname>

${_this_filename} :
   -f <input_file>         file with data collected by HCP-CS MAPI endpoint /instances
                           if this option is specified, -d and -s options are ignored

   -o <output_file>        output parsed file name (default: ${_default_output_file}

   -d <dir-name>           directory name to search for input file with a shortname

   -s <input-file-shortname>  short name of input file to search in <dir-name>
                              default: ${_default_input_file_shortname}
"
}


##############################
#
# Check the input parameters:
#
getOptions() {
    while getopts "f:d:s:o:vh" _opt; do
        case "${_opt}" in
            f)  _input_file="${OPTARG}"
                ;;

            d)  _dir_name="${OPTARG}"
                ;;

            s)  _input_file_shortname="${OPTARG}"
                ;;

            v)  _verbose="true"
                ;;

            o)  _output_file="${OPTARG}"
                ;;

            *)  usage
                exit 0
                ;;
        esac
    done
}


############################

getOptions "$@"

# Check if an exact input file specified or it needs to be searched in <dir-name>
if [[ "${_input_file}" != "" ]]; then
    if [[ -f "${_input_file}" ]]; then
        _input_json_file="${_input_file}"
    else
        echo "ERROR: CANNOT FIND ${_input_file} file."
        exit 1
    fi
else
    if [[ "${_dir_name}" != "" ]]; then
        if [[ -d "${_dir_name}" ]]; then
            _input_json_file=$(gsc_find_file "${_dir_name}" "${_input_file_shortname}")
        else
            echo "ERROR: CANNOT FIND ${_dir_name} directory."
            exit 1
        fi
    else
        echo "ERROR: MISSING INPUT PARAMETERS: specify either -f or -d options."
        exit 1
    fi
fi

# Check if the input file exists
if [[ "${_input_json_file}" == "" ]]; then
    echo "ERROR: CANNOT FIND ${_input_file_shortname} file in ${_dir_name} directory."
    exit 1
fi

if [[ ! -f "${_input_json_file}" ]]; then
    echo "ERROR: CANNOT FIND ${_input_json_file} file"
    exit 1
fi

# Rotate output file if it already exists
gsc_rotate_log "${_output_file}"

##################

_service_names=()
_service_ips=()
_services_list=()
_service_ip_count=()

# Find the element in array that matches the service name
find_service() {
    local _ret=-1
    local _nn=0
    local _sname
    for _sname in "${_service_names[@]}"; do
        if [[ "${_sname}" == "$1" ]]; then
            _ret="${_nn}"
            break
        fi
        _nn=$((_nn + 1))
    done
    echo "${_ret}"
}


########################## START ###################

gsc_loga "Parsing ${_input_json_file} file"

# Check if the 1st line is a comment and needs to be removed before processing by jq
_first_line=$(head -n 1 "${_input_json_file}")
if [[ "${_first_line}" == "#"* ]]; then
    _instances_services_list=$(tail -n +2 "${_input_json_file}" | jq .)
else
    _instances_services_list=$(jq . "${_input_json_file}")
fi

if [[ -z "${_instances_services_list}" ]]; then
    echo "Couldn't collect information about services, exiting..."
    exit 1
fi

gsc_log_debug "${_instances_services_list}"

_instance_count=$(echo "${_instances_services_list}" | jq 'length')
if [[ "${_instance_count}" == "0" ]]; then
    echo "ERROR: no instance is detected, exiting..."
    exit 1
fi

gsc_loga "# Service information for HCP-CS: ${_input_json_file}"

gsc_loga "${_instance_count} nodes"

gsc_loga "======== Display HCP-CS services on each node: "
# Enumerate all instances and then enumerate all services on each instance:
for (( _ii=0; _ii<_instance_count; _ii++ )); do
    _services_list[${_ii}]=""

    _instance_ip=$(echo "${_instances_services_list}" | jq -r '.['"${_ii}"'].externalIpAddress')

    _service_count=$(echo "${_instances_services_list}" | jq -r '.['"${_ii}"'].services | length')

    _hh=0
    for (( _jj=0; _jj<_service_count; _jj++ )); do
        _service_name=$(echo "${_instances_services_list}" | jq -r '.['"${_ii}"'].services['"${_jj}"'].name')
        _service_status=$(echo "${_instances_services_list}" | jq -r '.['"${_ii}"'].services['"${_jj}"'].status')

        _hh=$(find_service "${_service_name}")
        if [[ "${_hh}" == "-1" ]]; then
            _hh=${#_service_names[@]}
            _service_names[${_hh}]="${_service_name}"
            _service_ips[${_hh}]="${_instance_ip}"
            _service_ip_count[${_hh}]=1
        else
            _service_ips[${_hh}]+=", ${_instance_ip}"
            ((_service_ip_count[${_hh}]+=1))
        fi

        _ver=""
        if [[ "true" == "${_verbose}" ]]; then
            _ver="$((_hh+1)))"
        fi

        if [[ "" == "${_services_list[${_ii}]}" ]]; then
            _services_list[${_ii}]="${_ver}${_service_name}"
        else
            _services_list[${_ii}]+=", ${_ver}${_service_name}"
        fi

        if [[ "Healthy" != "${_service_status}" ]]; then
            _service_ips[${_hh}]+="(${_service_status})"
            _services_list[${_ii}]+="(${_service_status})"
        fi
    done

    # Display services per instance
    gsc_loga "[$((${_ii}+1))] ${_instance_ip}: ${_service_count} services= ${_services_list[${_ii}]}"
done



# Display instances per service
gsc_loga "======== Display all ${#_service_names[@]} HCP-CS services and the nodes they are running on: "
_nn=0
for _service_name in "${_service_names[@]}"; do
    _ip_addrs="${_service_ips[${_nn}]}"
    _node_count="${_service_ip_count[${_nn}]}"

    _s=""
    if (( _node_count > 1 )); then _s="s"; fi

    _nn=$((_nn + 1))
    gsc_loga "${_nn})${_service_name}: ${_node_count} node${_s}: ${_ip_addrs}"
done

gsc_log_info "Log file ${_output_file} was generated."
