#!/usr/bin/env bash
#
# ========================================================================
# Copyright (c) by Hitachi, 2021-2024. All rights reserved.
# ========================================================================
#
# It checks information about HCP-CS system alerts/events.
#

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${_script_dir}/gsc_core.sh"

_debug=0                # debug mode
_verbose="false"        # verbose

_default_output_file="health_report_alerts_events.log"
_default_alerts_file_short="get-config_aspen_alert-list.out"
_default_events_file_short="get-config_aspen_system-info.out"
_default_time_ago="30 days"

_log_dir="."
_output_file=${_default_output_file}
_time_ago=${_default_time_ago}
_tools_dir="${_script_dir}"

usage() {
    local _this_filename
    _this_filename=$(basename "$0")

    echo "\
This script validates/checks system alerts/events.

${_this_filename} -d <dir-name> -o <output-file>

${_this_filename} :

   -d <dir-name>                directory with input files

   -o <output_log_file>         output log file (default: ${_default_output_file}

   -t <time-ago>                check events recorded since some time ago (default: ${_default_time_ago})
                                possible options: hours, minutes, seconds. E.g. '2 hours', '30 minutes'

"
}

##############################
#
# Check the input parameters:
#
getOptions() {
    local _opt
    while getopts "d:o:t:vh" _opt; do
        case ${_opt} in
            d)  _log_dir=${OPTARG}
                ;;

            v)  _verbose="true" ; _debug=1
                ;;

            o)  _output_file=${OPTARG}
                ;;

            t)  _time_ago=${OPTARG}
                ;;

            *)  usage
                exit 0
                ;;
        esac
    done
}

############################

getOptions "$@"

# Checking input log directory and prep output file

# Check if LOG DIR exists
if [[ "${_log_dir}" != "" && ! -d ${_log_dir} ]]; then
    gsc_log_info "ERROR: CANNOT FIND ${_log_dir} directory."
    exit
fi

# Check if output file exists and if so, rename it
if [[ -f ${_output_file} ]]; then
    mv ${_output_file} ${_output_file}.bak
fi


#########################
# START CHECKING ALERTS AND EVENTS INFO
#
# etime based on ${_time_ago}
_etime_time_ago=$(date -d "${_time_ago} ago" +%s)

gsc_log_info "# Checking System Alerts"
# Check if an alert file is found
_alerts_file=$(find ${_log_dir} | grep -m 1 ${_default_alerts_file_short} | head -n 1)
if [[ "${_alerts_file}" == "" ]]; then
    gsc_log_warn "WARNING: CANNOT FIND ${_default_alerts_file_short} file in ${_log_dir}"
else
    # Check if the 1st line is the comment and needs to me removed before processing by jq
    _first_line=$(head -n 1 ${_alerts_file})
    if [[ "${_first_line}" == "#"* ]]; then
        _alerts_json=$(tail -n +2 ${_alerts_file})
        ((_num_lines=$(wc -l < ${_alerts_file}) -1))
    else
        _alerts_json=$(cat ${_alerts_file})
        _num_lines=$(wc -l < ${_alerts_file})
    fi

    if [[ "${_alerts_json}" == "" || "$(gsc_is_json "${_alerts_json}")" == "false" ]]; then
        gsc_log_warn "WARNING: INPUT ALERTS FILE: ${_alerts_file} - NOT EXPECTED FORMAT"
        gsc_log_info "Number of lines: ${_num_lines}"
        gsc_log_info "First line: ${_first_line}"
        gsc_log_debug "${_alerts_json}"
        _alerts_json=""
    fi
fi

if [[ "${_alerts_json:-}" != "" ]] ; then

    _alerts=$(echo "${_alerts_json}" | jq -r '.[] | "\(.timestamp) \(.category) \(.description)"')
    _alerts_sec=$(echo "${_alerts}" | awk ' { $1=int($1/1000); print $0 } ')

    _alerts_time_ago=$(echo "${_alerts_sec}" | awk -v ETIME=${_etime_time_ago} ' { if ($1 > ETIME) { $1=strftime("%Y-%b-%d",$1); print $0 } }')

    if [[ "${_alerts_time_ago}" == "" ]]; then
        gsc_log_info "No system alerts in the past ${_time_ago}"
    else
        _num_alerts=$(echo "${_alerts_time_ago}" | wc -l)
        gsc_loga "WARNING: ${_num_alerts} alerts in the past ${_time_ago}:"
        gsc_loga "${_alerts_time_ago}"
    fi
fi


gsc_log_info "# Checking System Events"

# Check if an event file is found
_events_file=$(find ${_log_dir} | grep -m 1 ${_default_events_file_short} | head -n 1)
if [[ "${_events_file}" == "" ]]; then
    gsc_log_warn "WARNING: CANNOT FIND ${_default_events_file_short} file in ${_log_dir}"
else
    # Check if the 1st line is the comment and needs to me removed before processing by jq
    _first_line=$(head -n 1 ${_events_file})
    if [[ "${_first_line}" == "#"* ]]; then
        _events_json=$(tail -n +2 ${_events_file})
        ((_num_lines=$(wc -l < ${_events_file}) -1))
    else
        _events_json=$(cat ${_events_file})
        _num_lines=$(wc -l < ${_events_file})
    fi

    if [[ "${_events_json:-}" == "" || "$(gsc_is_json "${_events_json:-}")" == "false" ]]; then
        gsc_log_warn "WARNING: INPUT EVENTS FILE: ${_events_file} - NOT EXPECTED FORMAT"
        gsc_log_info "Number of lines: ${_num_lines}"
        gsc_log_info "First line: ${_first_line}"
        gsc_log_debug "${_events_json:-}"
        _events_json=""
    fi
fi

if [[ "${_events_json:-}" != "" ]] ; then

    _num_events=$(echo "${_events_json}" | jq -r '.events[].time' | awk -v ETIME=${_etime_time_ago} ' $1 > ETIME ' | wc -l)

    if (( ${_num_events} > 0 )); then

        _events=$(echo "${_events_json}" | jq -r '.events[] | "\(.timestamp) \(.severity) \(.subsystem) \(.subject) \(.message)"')

        gsc_log_debug "$(echo "${_events}" | wc -l) events"

        _uniq_events=$(echo "${_events}" | grep -v "INFO" | sort -u -t' ' -k4,4)

        _uniq_events_sec=$(echo "${_uniq_events}" | awk ' { $1=int($1/1000); print $0 } ')

        _uniq_events_time_ago=$(echo "${_uniq_events_sec}" | awk -v ETIME=${_etime_time_ago} '{ if ($1 > ETIME) { $1=strftime("%Y-%b-%d",$1); print $0 } }')

        if [[ "${_uniq_events_time_ago}" == "" ]]; then
            gsc_log_info "No system events in the past ${_time_ago}"
        else
            _num_events=$(echo "${_uniq_events_time_ago}" | wc -l)
            gsc_loga "WARNING: ${_num_events} types of events in the past ${_time_ago}:"
            gsc_loga "${_uniq_events_time_ago}"
        fi
    fi

fi

gsc_log_info "Completed Alerts and Events processing. Report file: ${_output_file}."
