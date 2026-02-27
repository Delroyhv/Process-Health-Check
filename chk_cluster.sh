#!/usr/bin/env bash
#
# ========================================================================
# Copyright (c) by Hitachi, 2021-2024. All rights reserved.
# ========================================================================
#
# It checks information about the HCP-CS cluster configuration.
#

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${_script_dir}/gsc_core.sh"

_log_dir=${1:-"."}
_debug=0
_output_file="health_report_cluster.log"

gsc_rotate_log "${_output_file}"

###################################################

_latest_version="2.6.1.68"

_product_version_short="product.version"
_cluster_info_short="_productinfo_cluster.config"
_system_info_short="_get-config_aspen_system-info.out"

gsc_log_info "== CHECKING CLUSTER CONFIG =="

_product_version_file=$(gsc_find_file "${_log_dir}" "${_product_version_short}")
if [[ "${_product_version_file}" == "" ]]; then
    gsc_loga "WARNING: CANNOT FIND ${_product_version_short} in ${_log_dir} directory."
elif [[ ! -f ${_product_version_file} ]]; then
    gsc_loga "WARNING: CANNOT FIND ${_product_version_file} file."
else
    _version_num=$(cat ${_product_version_file} | tr -d "hcpcs/")
    if [[ "${_version_num}" == "" ]]; then
        gsc_loga "WARNING: ${_product_version_file} DOES NOT CONTAIN HCP-CS VERSION NUMBER."
    else
        gsc_loga "NOTICE: HCP-CS version: ${_version_num}"
        if [[ "${_version_num}" != "${_latest_version}" ]]; then
            gsc_loga "WARNING: product version ${_version_num} is not the latest (${_latest_version})"
        fi
    fi
fi

####
_cluster_info_file=$(gsc_find_file "${_log_dir}" "${_cluster_info_short}")
if [[ "${_cluster_info_file}" == "" ]]; then
    gsc_loga "WARNING: CANNOT FIND ${_cluster_info_short} in ${_log_dir} directory."
elif [[ ! -f ${_cluster_info_file} ]]; then
    gsc_loga "WARNING: CANNOT FIND ${_cluster_info_file} file."
else

    # Get External subnet info
    _external_subnet=$(cat ${_cluster_info_file} | grep "external=" | grep -v "_" | awk -F"=" '{ print $2 }')
    if [[ "${_external_subnet}" == "" ]]; then
        gsc_loga "WARNING: ${_cluster_info_file} DOES NOT CONTAIN EXTERNAL SUBNET INFO."
    else
        gsc_loga "NOTICE: External subnet: ${_external_subnet}"
    fi

    # Get Internal subnet info
    _internal_subnet=$(cat ${_cluster_info_file} | grep "internal=" | awk -F"=" '{ print $2 }')
    if [[ "${_internal_subnet}" == "" ]]; then
        gsc_loga "WARNING: ${_cluster_info_file} DOES NOT CONTAIN INTERNAL SUBNET INFO."
    else
        gsc_loga "NOTICE: Internal subnet: ${_internal_subnet}"
    fi

    # Check if both internal and external subnets are used
    if [[ "${_internal_subnet}" == "${_external_subnet}" ]]; then
        gsc_loga "WARNING: one subnets for internal and external networks"
    fi

    # Check if debug mode
    _debug_mode=$(cat ${_cluster_info_file} | grep "debug=" | awk -F"=" '{ print $2 }')
    if [[ "${_debug_mode}" != "" && "${_debug_mode}" != "false" ]]; then
        gsc_loga "WARNING: DEBUG MODE IS ${_debug_mode}"
    fi
fi

####
_system_info_file=$(gsc_find_file "${_log_dir}" "${_system_info_short}")
if [[ "${_system_info_file}" == "" ]]; then
    gsc_loga "WARNING: CANNOT FIND ${_system_info_short} in ${_log_dir} directory."
elif [[ ! -f ${_system_info_file} ]]; then
    gsc_loga "WARNING: CANNOT FIND ${_system_info_file} file."
else
    _install_dir=$(head -n 1 ${_system_info_file} | awk -F"/" '{ print "/" $2 "/" $3 }')
    gsc_loga "NOTICE: install dir: ${_install_dir}"
fi
