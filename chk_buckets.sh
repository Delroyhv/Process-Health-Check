#!/usr/bin/env bash
#
# ========================================================================
# Copyright (c) by Hitachi, 2021-2024. All rights reserved.
# ========================================================================
#
# Report S3 buckets and detected backup/application types from
# get-user-buckets data collected in the support bundle.
#
# By default prints bucket name and inferred application.
# With --bucket-owner also prints the bucket owner (user display name).
#

_default_output_file="health_report_buckets.log"
_log_dir="."
_output_file="${_default_output_file}"
_show_owner="false"

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=gsc_core.sh
. "${_script_dir}/gsc_core.sh"

usage() {
    local _this_filename
    _this_filename=$(basename "$0")
    echo "\
Report S3 buckets and detected applications from support bundle data.

${_this_filename} [-d <dir>] [-o <output>] [--bucket-owner]

  -d <dir>          directory with support bundle (default: .)
  -o <output>       output log file (default: ${_default_output_file})
  --bucket-owner    also print bucket owner (user display name)
"
}

getOptions() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d) _log_dir="$2"; shift 2 ;;
            -o) _output_file="$2"; shift 2 ;;
            --bucket-owner) _show_owner="true"; shift ;;
            -h|--help) usage; exit 0 ;;
            *) usage; exit 1 ;;
        esac
    done
}

infer_app() {
    local _bucket="$1"
    case "${_bucket}" in
        cvlt-*|*comvlt*|*commvault*) echo "Commvault"     ;;
        *veeam*)                     echo "Veeam"          ;;
        *syslog*|*elastic*)          echo "Tools/Logging"  ;;
        *sftp*)                      echo "SFTP"           ;;
        *replica*)                   echo "Replication"    ;;
        *test*|*chum*|*dev*)         echo "Test/Dev"       ;;
        *)                           echo "Unknown"        ;;
    esac
}

############################

getOptions "$@"

gsc_log_info "== CHECKING S3 BUCKET APPLICATIONS =="

gsc_rotate_log "${_output_file}"

# Locate user-list file
_user_list=$(find "${_log_dir}" -name '*get-config_aspen_user-list.out' 2>/dev/null | sort | tail -1)
if [[ -z "${_user_list}" ]]; then
    gsc_log_warn "No user-list file found in ${_log_dir} — bucket owner names unavailable"
fi

# Locate get-user-buckets cmd/out pairs
mapfile -t _bucket_cmds < <(find "${_log_dir}" -name '*get-user-buckets.cmd' 2>/dev/null | sort)
if [[ "${#_bucket_cmds[@]}" -eq 0 ]]; then
    gsc_log_warn "No get-user-buckets files found in ${_log_dir}"
    gsc_loga "WARNING: No bucket data found"
    exit 0
fi

# Build uid -> display name map
declare -A _unames
if [[ -n "${_user_list}" ]]; then
    while IFS=' ' read -r _uid _uname; do
        _unames["${_uid}"]="${_uname}"
    done < <(grep -v '^#' "${_user_list}" | jq -r '.[] | .id + " " + .displayName' 2>/dev/null)
fi

# Collect unique bucket->owner entries
declare -A _bucket_owner
declare -a _bucket_order

for _cmd in "${_bucket_cmds[@]}"; do
    _uid=$(grep -o '\-i [^ ]*' "${_cmd}" 2>/dev/null | awk '{print $2}' | head -1)
    _out="${_cmd%.cmd}.out"
    [[ ! -f "${_out}" ]] && continue
    while IFS= read -r _bname; do
        [[ -z "${_bname}" ]] && continue
        if [[ -z "${_bucket_owner[${_bname}]+x}" ]]; then
            _bucket_owner["${_bname}"]="${_uid}"
            _bucket_order+=("${_bname}")
        fi
    done < <(grep -v '^#' "${_out}" | jq -r '.[] | .bucketName' 2>/dev/null)
done

if [[ "${#_bucket_order[@]}" -eq 0 ]]; then
    gsc_loga "INFO: No buckets found in bundle"
    exit 0
fi

# Print header and rows
if [[ "${_show_owner}" == "true" ]]; then
    gsc_loga "$(printf '%-35s %-20s %s' 'Bucket' 'Application' 'Owner')"
    gsc_loga "$(printf '%-35s %-20s %s' '------' '-----------' '-----')"
else
    gsc_loga "$(printf '%-35s %s' 'Bucket' 'Application')"
    gsc_loga "$(printf '%-35s %s' '------' '-----------')"
fi

for _bname in "${_bucket_order[@]}"; do
    _app=$(infer_app "${_bname}")
    _uid="${_bucket_owner[${_bname}]}"
    _owner="${_unames[${_uid}]:-${_uid}}"
    if [[ "${_show_owner}" == "true" ]]; then
        gsc_loga "$(printf '%-35s %-20s %s' "${_bname}" "${_app}" "${_owner}")"
    else
        gsc_loga "$(printf '%-35s %s' "${_bname}" "${_app}")"
    fi
done

gsc_loga ""
gsc_loga "Total buckets: ${#_bucket_order[@]}"
gsc_log_info "Saved results ${_output_file}"
