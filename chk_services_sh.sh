#!/usr/bin/env bash
# ========================================================================
# Copyright (c) by Hitachi, 2024. All rights reserved.
# ========================================================================
#
# It checks whether HCP for Cloud Scale service's run scripts were modified from the initially deployed.
#

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${_script_dir}/gsc_core.sh"

##############################
#
# DEFAULT PARAMETERS:
#
_default_dir_name="."
_default_services_sh_dir_prefix="services_sh"

_default_version_num="2.6"
_default_output_file="health_report_services_sh.log"

_services=(
"coordination"
"data-lifecycle"
"data"
"gateway"
"mapi"
"rabbitMQServer"
)
# "mirror-in"
# "mirror-out"
# "s3-notifications"
# "prometheus"

##########
# Usage
#
usage() {
    local _this_filename
    _this_filename=$(basename "$0")

    echo "\
This script collects various metrics from HCP for Cloud Scale cluster.
Usage: ${_this_filename} -d <dir-name> -o <output-file> -v <info|debug>

${_this_filename} :

  -d <dir-name>             Optional    Directory name with with services' run files

  -r <HCP-CS-release>       Optional    HCP-CS version number(default: ${_default_version_num})

  -o <output-file>          Optional    Output file (default: '${_default_output_file}')

  -v [info | debug]         Optional    Verbose mode: info or debug

  -h                        Optional    This message
"
}

##

_chktools_dir="${_script_dir}"
_log_dir=${_default_dir_name}
_version_num=${_default_version_num}

_services_sh_dir="${_chktools_dir}/${_default_services_sh_dir_prefix}"
_output_file=${_default_output_file}

_verbose=""

##############################
#
# Check the input parameters:
#
getOptions() {
    local _opt
    while getopts "d:r:b:v:o:h" _opt; do
        case ${_opt} in
            o)  _output_file=${OPTARG}
                ;;

            v)  _verbose=${OPTARG}
                ;;

            r)  _version_num=${OPTARG}
                ;;

            d)  _log_dir=${OPTARG}
                ;;

            b)  _services_sh_dir=${OPTARG}
                ;;

            *)  usage
                exit 0
                ;;
        esac
    done
}

####################################################

getOptions "$@"

gsc_log_info "== CHECKING SERVICE'S RUN CONFIG =="

if [[ -f ${_output_file} ]]; then
    mv ${_output_file} ${_output_file}.bak
fi

_err=0

# construct $_services_sh_dir for a specified version, unless users specified _services_sh_dir (-b input parameter)
# Prefer _cs_version (from healthcheck.conf) if present, otherwise fall back to _version_num
if [[ -n "${_cs_version:-}" ]]; then
    _version_family="${_cs_version}"
else
    _version_family="${_version_num}"
fi

if [[ "${_services_sh_dir}" == "${_chktools_dir}/${_default_services_sh_dir_prefix}" && -n "${_version_family}" ]]; then
    _suffix=""
    case "${_version_family}" in
        2.5.*)
            _suffix="25"
            ;;
        2.6.*)
            _suffix="26"
            ;;
        *)
            # Fallback: use major.minor family, e.g. 3.1.x -> "31"
            _suffix="$(echo "${_version_family}" | cut -d"." -f1,2 | tr -d ".")"
            ;;
    esac
    _services_sh_dir="${_chktools_dir}/${_default_services_sh_dir_prefix}_${_suffix}"
fi

# Find a directory with service sh files in ${_log_dir}
_full_filename=$(find ${_log_dir} | grep -m 1 "coordination\.sh" | head -n 1)
if [[ "${_full_filename}" == "" ]]; then
    gsc_log_error "ERROR: cannot find service's sh files in ${_log_dir} and its subdirectories."
    exit
fi

_collected_output_files_dir=$(dirname ${_full_filename})

gsc_log_info "Comparing service's sh files in ${_collected_output_files_dir} with the default files."

_warn=0

for _service in "${_services[@]}"; do

    if [[ ! -f ${_services_sh_dir}/${_service}.sh ]]; then
        gsc_log_warn "WARNING: ${_services_sh_dir}/${_service}.sh NOT found - skipping comparison for this service"
        ((_warn++))
        continue
    fi

    _files=$(ls -1 ${_collected_output_files_dir}/*_${_service}.sh 2>/dev/null || true)

    if [[ "${_files}" == "" ]] ; then
        gsc_log_error "ERROR: missing ${_service}.sh file in ${_log_dir}"
    else
        _modified_nodes=()
        while IFS= read -r _file; do
            [[ -z "${_file}" ]] && continue
            _node=$(echo "${_file}" | awk -F"node_info_" ' { print $2 } ' | awk -F"_" '{ print $1 }')

            if ! diff -qB "${_file}" "${_services_sh_dir}/${_service}.sh" >/dev/null 2>&1; then
                _modified_nodes+=("${_node}")
                ((_warn++))
                # Log specific node detail to the output log file
                printf 'WARNING: %s.sh was modified on node %s\n' "${_service}" "${_node}" >> "${_output_file}"
            elif [[ "${_verbose}" != "" ]]; then
                gsc_loga "INFO: ${_service}.sh was NOT modified on node ${_node}"
            fi
        done <<< "${_files}"

        if [[ ${#_modified_nodes[@]} -gt 0 ]]; then
            gsc_loga "WARNING: ${_service}.sh was modified on ${#_modified_nodes[@]} node(s) — refer to logs for details"
        fi
    fi
done

if [[ "${_warn}" == "0" ]]; then
    gsc_loga "INFO: no service run files were modified"
else
    gsc_loga "WARNING: ${_warn} service run files modified"
fi
gsc_log_info "Saved results ${_output_file}"
