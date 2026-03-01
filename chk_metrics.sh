#!/usr/bin/env bash
# ========================================================================
# Copyright (c) by Hitachi, 2024. All rights reserved.
# ========================================================================
#
# It collects various metrics from the HCP for Cloud Scale system.
#
_script_version="0.0.1"

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${_script_dir}/gsc_core.sh"

##############################
#
# DEFAULT PARAMETERS:
#
_default_json_file="hcpcs_hourly_alerts.json"
_default_port="9191"
_default_dir_name="./supportLogs"

_http_string="http"
_https_string="https"
_default_proto=${_https_string}
_non_default_proto=${_http_string}

_default_probes_interval=300  # in seconds
_default_probes_num=24
_max_probes_num=4000 # avoid too many probes to process (may need to adjust the MAX)

_default_output_file_prefix="health_report_metrics"
_forced_proto="false"

_default_threshold="1000000000"

_threshold=${_default_threshold}


##########
# Usage
#
usage() {
    local _this_filename
    _this_filename=$(basename "$0")

    echo "\
This script collects various metrics from HCP for Cloud Scale cluster.
Version: ${_script_version}
Usage: ${_this_filename} -c <prometheus-fqdn> [-n <port>] [-t <date>] [-s <http-proto>] [-f <metrics-json-file>] [-o <output-file-prefix>] [-v info]
e.g. ${_this_filename} -c hcpcs.example.com
     ${_this_filename} -c hcpcs.example.com -t 2024-08-19T20:10:30.781Z -i 600 -e 120
     ${_this_filename} -c hcpcs.example.com -n 9090 -s http -t 2024-08-19T20:10:30.781Z
     ${_this_filename} -c hcpcs.example.com -n 9095 -f my_metrics.json -v info

${_this_filename} :
  -c <prometheus>           Required    FQDN or IP address of Prometheus, optionally with a port number

  -n <port>                 Optional    Port number (default: ${_default_port})

  -t <date>                 Optional    Date and time in the following format: '2024-08-19T20:10:30.781Z'
                                        default is the current time (now)

  -f <metrics-json-file>    Optional    File with a list of metrics (default: ${_default_json_file})

  -b                        Optional    Disables probes mode (switches to a single-query mode)

  -e <number-probes>        Optional    Number of probes (default: ${_default_probes_num})

  -i <probes-interval>      Optional    Interval between the probes in seconds (default: ${_default_probes_interval} sec)

  -s <http-protocol>        Optional    http or https (default: https)

  -o <output-file-prefix>   Optional    Output file prefix (default: '${_default_output_file_prefix}')

  -v info                   Optional    Verbose mode: info

  -h                        Optional    This message
"
}

##############################
#
# INPUT PARAMETERS:
#
_prom_proto=${_default_proto}
_prom_name=""    # FQDN or IP address of Prometheus
_prom_port=${_default_port}
_pdate=""

_use_internal_test_metrics="false"
_metrics_json_file="${_script_dir}/${_default_json_file}"

_output_file_prefix=${_default_output_file_prefix}
_dir_name=${_default_dir_name}

_date_suffix=""
_verbose=""
_debug=0

_probes_enabled="true"
_probes_interval=${_default_probes_interval} # in seconds
_probes_num=${_default_probes_num}

_oldest_date_epoch=0  # Prometheus oldest date - epoch time

##############################
#
# Check the input parameters:
#
getOptions() {
    local _opt
    while getopts "c:d:v:f:e:i:n:o:q:m:t:s:bwh" _opt; do
        case ${_opt} in
            c)  _prom_name=${OPTARG}
                ;;

            o)  _output_file_prefix=${OPTARG}
                ;;

            v)  _verbose=${OPTARG}
                ;;

            f)  _metrics_json_file=${OPTARG}
                ;;

            n)  _prom_port=${OPTARG}
                ;;

            b)  _probes_enabled="false"
                ;;

            e)  _probes_num=${OPTARG}
                ;;

            m)  _max_probes_num=${OPTARG} # adjust _max_probes_num - hidden option
                ;;

            i)  _probes_interval=${OPTARG}
                ;;

            t)  _pdate=${OPTARG}
                ;;

            q)  _threshold=${OPTARG}
                ;;

            s)  _prom_proto=${OPTARG}
                _forced_proto="true"
                ;;

            w)  _use_internal_test_metrics="true"  # hidden option - for internal use only
                ;;

            *)  usage
                exit 0
                ;;
        esac
    done
}

_sii=0
###############################
#
# Display a spinner
#
spinner() {
    gsc_spinner
}

###############################
# Compare value against a provided limit, using a provided operator (> < == !=)
#
# Input:
#   $1 - value to check
#   $2 - operator ( >  <  ==  !=)
#   $3 - limit
#
# Output:
#   A message, if a provided condition is a match, or an empty string if no match.
#
compare_value() {
    gsc_compare_value "$1" "$2" "$3"
}


###############################
# Check value for the warning and error conditions
#
# Input:
#   $1 - value to check
#   $2 - warning criteria
#   $3 - error criteria
#   $4 - ignore_criteria
#
# Output: json string
#   {"level":"ERROR", "message":"${_crit_ret}"}
#   {"level":"WARNING", "message":"${_warn_ret}"}
#   {"level":"INFO", "message":"no issues (${_value})"}
#   {"level":"TELEMETRY", "message":"(${_telem_ret})" } # telemetry
#
check_value() {
    local _value=$1
    local _warning_criteria=$2
    local _error_criteria=$3
    local _ignore_criteria=$4
    local _ret="" _crit_ret="" _warn_ret="" _telem_ret="" _ignore_ret="" _comment=""
    local _ignore_operator="" _ignore_limit=""
    local _warning_operator="" _warning_limit=""
    local _critical_operator="" _critical_limit=""

    if [[ "$(gsc_is_empty "${_ignore_criteria}")" != "true" ]]; then
        _ignore_operator=$(echo "${_ignore_criteria}" | awk ' { print $1 } ')
        _ignore_limit=$(echo "${_ignore_criteria}" | awk ' { print $2 } ')
        _comment=$(echo "${_ignore_criteria}" | awk '{$1=$2="";print $0}')
        _ignore_ret=$(compare_value "$_value" "$_ignore_operator" "$_ignore_limit")
    fi

    # Ignore, if ignore-criteria OR if a value is negative
    if [[ "${_ignore_ret}" != "" || ( ${_value} == -*) ]]; then

        # skip if value is negative - it will be reported as INFO
        _value="IGNORE: ${_value} ${_comment}"

    elif [[ "$(gsc_is_empty "${_warning_criteria}")" == "true" && "$(gsc_is_empty "${_error_criteria}")" == "true" ]]; then

        _telem_ret="${_value}"  # report it as a Telemetry if no Warning/Error criteria

    else

        if [[ "$(gsc_is_empty "${_warning_criteria}")" != "true" ]]; then
            _warning_operator=$(echo "${_warning_criteria}" | awk ' { print $1 } ')
            _warning_limit=$(echo "${_warning_criteria}" | awk ' { print $2 } ')
            _warn_ret=$(compare_value "$_value" "$_warning_operator" "$_warning_limit")
        fi

        if [[ "$(gsc_is_empty "${_error_criteria}")" != "true" ]]; then
            _critical_operator=$(echo "${_error_criteria}" | awk ' { print $1 } ')
            _critical_limit=$(echo "${_error_criteria}" | awk ' { print $2 } ')
            _crit_ret=$(compare_value "$_value" "$_critical_operator" "$_critical_limit")
        fi
    fi

    if [[ "${_crit_ret}" != "" ]]; then
        _ret='{"level":"ERROR", "message":"'${_crit_ret}'"}'
    elif [[ "${_warn_ret}" != "" ]]; then
        _ret='{"level":"WARNING", "message":"'${_warn_ret}'"}'
    elif [[ "${_telem_ret}" != "" ]]; then
        _ret='{"level":"TELEMETRY", "message":"'${_telem_ret}'"}'
    else
        _ret='{"level":"INFO", "message":"'${_value}'"}'
    fi

    echo "$_ret"
}

####################
#
# Get a date format
#
# Input:
#    $1 - time in seconds (epoch)
#
# Output:
#    e.g. 2024-08-19T20:10:30.781Z
#
get_date_format() {
    gsc_get_date_format "$1"
}


###############################
#
# Convert all data for a message into json format - for the Error/Warning types
#
#  $1: eventId
#  $2: description
#  $3: check_data_json
#  $4: value_json [timestamp, "value"]
#  $5: label_name (optional)
#  $6: label (optional)
#
# Output:
#    json format:
#      {"eventId":"$1", "description":"$2", "check_data":$3, "value":$4}
#      {"eventId":"$1", "description":"$2", "check_data":$3, "value":$4, "label_name":"$5", "label":"$6"}
#
message_format_json_conditional() {
    local _label_name=$5
    local _label=$6

    local _message_json
    _message_json='{"eventId":"'$1'", "description":"'$2'", "check_data":'$3', "value":'$4
    if [[ "$(gsc_is_empty "${_label}")" != "true" ]]; then
        _message_json+=',"label_name":"'${_label_name}'", "label":"'${_label}'"'
    fi
    _message_json+='}'
    echo "${_message_json}"
}

###############################
#
# Convert all data for a message into json format - for the Telemetry type
#
#  $1: eventId
#  $2: description
#  $3: check_data
#  $4: value-telemetry-json [timestamp-start, timestamp-end, "avg", "min", "max"]
#  $5: label_name (optional)
#  $6: label (optional)
#
# Output:
#    json format:
#      {"eventId":"$1", "description":"$2", "check_data":$3, "value_telem":$4}
#      {"eventId":"$1", "description":"$2", "check_data":$3, "value_telem":$4, "label_name":"$5", "label":"$6"}
#
message_format_json_telem() {
    local _value_telem_json=$4
    local _label_name=$5
    local _label=$6

    local _message_json
    _message_json='{"eventId":"'$1'","description":"'$2'", "check_data":'$3
    _message_json+=', "value_telem":'${_value_telem_json}

    if [[ "$(gsc_is_empty "${_label}")" != "true" ]]; then
        _message_json+=',"label_name":"'${_label_name}'", "label":"'${_label}'"'
    fi
    _message_json+='}'
    echo "${_message_json}"
}


###############################
#
# Convert all data for a message into json format - for the Consecutive type
#
#  $1: eventId
#  $2: description
#  $3: check_data_json
#  $4: consecutive_count
#  $5: probe_interval
#  $6: label_name (optional)
#  $7: label (optional)
#
message_format_json_consecutive() {
    local _consecutive_count=$4
    local _probe_interval=$5
    local _label_name=$6
    local _label=$7

    local _message_json
    _message_json='{"eventId":"'$1'","description":"'$2'", "check_data":'$3
    _message_json+=', "consecutive_count":'${_consecutive_count}', "probe_interval":'${_probe_interval}

    if [[ "$(gsc_is_empty "${_label}")" != "true" ]]; then
        _message_json+=',"label_name":"'${_label_name}'", "label":"'${_label}'"'
    fi
    _message_json+='}'
    echo "${_message_json}"
}

###############################
#
# Parse a message from json format into human-readable format
#
function message_format_print() {
    local _event_id _descr _check_data_json _value_json _value_telem_json _consecutive_count _probe_interval
    local _label_name _label _msg_count _level _msg _timestamp _time_info _avg _max _min _value
    local _label_info _all _output _timestamp_start _timestamp_end
    _event_id=$(echo "$1" | jq -rc '.eventId')
    _descr=$(echo "$1" | jq -rc '.description')
    _check_data_json="$(echo "$1" | jq -rc '.check_data')"
    _value_json="$(echo "$1" | jq -rc '.value')"
    _value_telem_json="$(echo "$1" | jq -rc '.value_telem')"
    _consecutive_count="$(echo "$1" | jq -rc '.consecutive_count')"
    _probe_interval="$(echo "$1" | jq -rc '.probe_interval')"
    _label_name=$(echo "$1" | jq -rc '.label_name')
    _label=$(echo "$1" | jq -rc '.label')
    _msg_count=$2
    _time_info=""
    _value=""
    _level=""
    _msg=""

    if [[ "$(gsc_is_empty "${_consecutive_count}")" != "true" ]]; then
        _level=$(echo "${_check_data_json}" | jq -c '.level' | tr -d '"')
        _msg=$(echo "${_check_data_json}" | jq -c '.message' | tr -d '"')
        _msg+=" - Consecutive ${_consecutive_count} probes, ${_probe_interval} seconds each"
    elif [[ "$(gsc_is_empty "${_value_json}")" != "true" ]]; then
        _value=$(echo "${_value_json}" | jq -rc '.[1]' | tr -d '"')
        if [[ "${_probes_enabled}" == "true" ]]; then
            _timestamp=$(echo "${_value_json}" | jq -rc '.[0]')
            _time_info=" [$(get_date_format "${_timestamp}")]"
        fi
        _msg=$(echo "${_check_data_json}" | jq -c '.message' | tr -d '"')
        _level=$(echo "${_check_data_json}" | jq -c '.level' | tr -d '"')
    elif [[ "$(gsc_is_empty "${_value_telem_json}")" != "true" ]]; then
        if [[ "${_probes_enabled}" == "true" ]]; then
            _timestamp_start=$(echo "${_value_telem_json}" | jq -rc '.[0]')
            _timestamp_end=$(echo "${_value_telem_json}" | jq -rc '.[1]')
            _time_info=" [$(get_date_format "${_timestamp_start}") - $(get_date_format "${_timestamp_end}")]"
        fi
        _avg=$(echo "${_value_telem_json}" | jq -rc '.[2]')
        _max=$(echo "${_value_telem_json}" | jq -rc '.[3]')
        _min=$(echo "${_value_telem_json}" | jq -rc '.[4]')
        _msg="Avg: ${_avg}, Max: ${_max}, Min: ${_min}"
        _level=$(echo "${_check_data_json}" | jq -c '.level' | tr -d '"')
    else
        gsc_log_debug "INTERNAL ERROR: message_format_print"
    fi

    _label_info=""
    if [[ "$(gsc_is_empty "${_label}")" != "true" && "$(gsc_is_empty "${_label_name}")" != "true" ]]; then
        _label_info=": [${_label}=${_label_name}]=${_value}"
    fi

    # If we got all probes in this query, use the word "all" (for more clarity)
    _all=""
    if [[ "${_msg_count}" == "${_probes_num}" ]]; then
        _all="all "
    fi

    # Output format - externally reported
    _output="${_level} : ${_event_id} : ${_descr} : ${_msg} ${_label_info}${_time_info} [${_all}${_msg_count} probes]"
    echo "${_output}"
}

#############################
#
# Get Oldest metric from Prometheus DB snapshot
#
# Output:
#    timestamp   if success (e.g. 2024-08-19T20:10:30.781Z)
#    "0"         if Prometheus query is successful but a value is not returned
#    ""          empty, if Prometheus query failed
#
getOldestMetricTimestamp() {
    local _err=0
    local _oldest_date=""
    local _description="Timestamp of the oldest metric in Prometheus DB"
    local _query="prometheus_tsdb_lowest_timestamp_seconds"
    local _metric_result _status

    gsc_log_debug "${_description}, Query=${_query}"

    _metric_result=$(make_query "${_query}" "")
    gsc_log_debug "metric_result=${_metric_result}"

    ### Metric output example:  "16" is the value
    # {"status":"success","data":{"resultType":"vector","result":[{"metric":{},"value":[1611945600.432,"16"]}]}}

    ### Get the "status" field from the result
    _status=$(echo "$_metric_result" | jq -c .status | tr -d '"')
    if [[ "$_status" == "success" ]] ; then

        ### Process successful query result
        _oldest_date_epoch=$(echo "$_metric_result" | jq -c .data.result[0].value[1] | tr -d '"')
        if [[ "$(gsc_is_empty "${_oldest_date_epoch}")" == "true" ]]; then
            gsc_log_debug "BLANK QUERY: getOldestMetricTimestamp: ${_query}, REPLY: ${_metric_result}"
            _err=1
            _oldest_date="0"
        fi
    else

        ### Failed query - record it
        gsc_log_debug "FAILED QUERY: getOldestMetricTimestamp: ${_query}, REPLY: ${_metric_result}"
        _err=2
    fi

    if [[ "${_err}" == "0" ]]; then
        _oldest_date=$(get_date_format "${_oldest_date_epoch}")
    fi

    echo "${_oldest_date}"
}

############################
# Make Prometheus query (single value)
#
# Input:
#     ${_prom_name} - FQDN or IP of Prometheus service
#     ${_prom_port} - port number of Prometheus service
#
#     $1 - prometheus query
#     $2 - date in the following format (2024-06-02T05:10:30.781Z)
#             or empty for the current time
#
# Output:
#     reply from Prometheus in json format
#
make_query() {
    local _metric=$1
    local _pdate_arg=$2
    local _urlenc_metric _result
    local -a _mycmd

    ### Convert query to URL encoding
    _urlenc_metric=$(echo "$_metric" | jq -sRr @uri)

    if [[ "${_pdate_arg}" != "" ]]; then
        _urlenc_metric+="&time=${_pdate_arg}"
    fi

    ### Form the query command (curl)
    _mycmd=(curl -s -k -X GET "${_prom_proto}://${_prom_name}:${_prom_port}/api/v1/query?query=${_urlenc_metric}")
    if [[ "${_debug}" == "2" ]]; then
        echo "mycmd=${_mycmd[*]}" >&2
    fi

    ### Run the query command on Prometheus:
    _result=$("${_mycmd[@]}")
    echo "${_result}"
}

############################
# Make Prometheus query_range (multiple values)
#
# Input:
#     ${_prom_name} - FQDN or IP of Prometheus service
#     ${_prom_port} - port number of Prometheus service
#
#     $1 - prometheus query
#     $2 - start timestamp (2024-06-02T05:10:30.781Z)
#     $3 - end timestamp (2024-06-02T05:10:30.781Z)
#     $4 - step (in seconds)
#
# Output:
#     reply from Prometheus in json format
#
make_query_range() {
    local _metric=$1
    local _start=$2
    local _end=$3
    local _step=$4
    local _urlenc_metric _result
    local -a _mycmd

    ### Convert query to URL encoding
    _urlenc_metric=$(echo "$_metric" | jq -sRr @uri)

    if [[ "${_start}" == "" || "${_end}" == "" || "${_step}" == "" ]]; then
        echo "INTERNAL ERROR: MISSING INPUT PARAMETERS FOR QUERY_RANGE ENDPOINT (&start=${_start}&end=${_end}&step=${_step})" >&2
        exit
    fi

    _urlenc_metric+="&start=${_start}&end=${_end}&step=${_step}s"

    ### Form the query command (curl)
    _mycmd=(curl -s -k -X GET "${_prom_proto}://${_prom_name}:${_prom_port}/api/v1/query_range?query=${_urlenc_metric}")

    if [[ "${_debug}" == "2" ]]; then
        echo "mycmd=${_mycmd[*]}" >&2
    fi

    ### Run the query command on Prometheus:
    _result=$("${_mycmd[@]}")
    echo "${_result}"
}

###
# List of metric queries for TESTING - internal-only
#
_metric_queries_test='
[
 {
  "Description":"DB Partitions per node limit",
  "Query":"(max(mcs_partitions_per_instance))",
  "Warning":"> 300", "_comments": "should be 1000",
  "Error": "> 1500"
 },
 {"Description":"DB used capacity in bytes (per node)",
  "Query":"metadata_used_capacity_bytes",
  "Warning":"> 700000",  "_comments": "should be >3000000000000 (3TB)",
  "Error":"> 850000000", "_comments": "should be >5000000000000 (5TB)",
  "Label":"store"
 },
 {
  "Description":"DB used capacity percentage (incl. aggregate)",
  "Query":"round(100*((topk(1, metadata_used_capacity_bytes) by (store)) / on (store) (topk(1, metadata_used_capacity_bytes+metadata_available_capacity_bytes) by (store))))",
  "Label":"store"
 },
 {
  "Description":"DB used capacity percentage (per node)",
  "Query":"round(100*((topk(1, metadata_used_capacity_bytes) by (store)) / on (store) (topk(1, metadata_used_capacity_bytes+metadata_available_capacity_bytes) by (store))))",
  "Warning":"> 10",  "_comments": "should be >70",
  "Error":"> 85",
  "Label":"store",
  "Exclude":"aggregate"
 }
]'

####################### INITIALIZATION ###############
#

getOptions "$@"


##### Validate input parameters ######
#
# Used for date validation (the date must be after 2020)
_test_epoch_time="1600000000" # September 13, 2020

if [[ "${_verbose}" == "info" ]]; then
    _debug=1
elif [[ "${_verbose}" == "debug" ]]; then
    _debug=2
elif [[ "${_verbose}" == "" ]]; then
    _debug=0
else
    echo "ERROR: Invalid verbose mode: ${_verbose} - if specified, must be either 'info' or 'debug'"
    exit
fi

# Validate Prometheus FQDN name
if [[ "${_prom_name}" == "" ]]; then
    gsc_log_error "Prometheus node name or IP is a required parameter"
    exit
fi

# Validate the date format
if [[ "$(gsc_is_empty "${_pdate}")" != "true" ]]; then
    _pdate_epoch=$(date -d "${_pdate}" +%s)
    if [[ "$(gsc_is_number "${_pdate_epoch}")" != "true" ]]; then
        echo "ERROR: DATE FORMAT IS INCORRECT: ${_pdate} (expected format: 2024-08-19T20:10:30.781Z)"
        exit
    elif [[ "${_pdate_epoch}" -lt "${_test_epoch_time}" ]]; then
        echo "ERROR: DATE IS TOO OLD: ${_pdate} (expected after 2020)"
        exit
    fi

    _pdate_epoch=$(date -u -d "${_pdate}" +%s)
    _date_suffix="$(date -u -d @${_pdate_epoch} +'%Y%b%d_%H%M%S%Z')"
fi

# Validate an input metrics json file
if [[ ! -f "${_metrics_json_file}" ]]; then
    echo "ERROR: CANNOT FIND METRICS JSON FILE: ${_metrics_json_file}"
    exit
fi

# Validate protocol (it must be either http or https)
if [[ "${_prom_proto}" != "" && "${_prom_proto}" != "${_https_string}" && ${_prom_proto} != "${_http_string}" ]]; then
    echo "ERROR: INVALID PARAMETER -s (${_prom_proto})"
    exit
fi

# Validate a probe interval (in seconds)
if [[ "$(gsc_is_number "${_probes_interval}")" != "true" ]]; then
    echo "ERROR: probes interval (in seconds) must be an integer number (${_probes_interval})"
    exit
fi

# Validate a number of probes (number of values in each metric request)
if [[ "$(gsc_is_number "${_probes_num}")" != "true" ]]; then
    echo "ERROR: number of probes must be an integer number (${_probes_num})"
    exit
fi

# Safety net - the number of probes shouldn't be too high
if (( _probes_num > _max_probes_num )); then
    echo "ERROR: number of probes must be equal or less than ${_max_probes_num} (${_probes_num} is too high)"
    exit
fi

# Metrics json file short name (no path, no extension)
_metrics_json_short=$(basename -- "${_metrics_json_file%.*}")

# Set the output log file
if [[ "${_prom_port}" == "${_default_port}" ]]; then
    _logfile_name="${_output_file_prefix}_${_prom_name}_${_metrics_json_short}_${_date_suffix}.log"
else
    _logfile_name="${_output_file_prefix}_${_prom_name}_${_prom_port}_${_metrics_json_short}_${_date_suffix}.log"
fi

_output_file="${_logfile_name}"
gsc_rotate_log "${_output_file}"

gsc_log_debug "Prometheus: ${_prom_proto}://${_prom_name}:${_prom_port}   Date: '${_pdate}'  Verbose: ${_verbose}"


#######################################################################################

################ START #####################################################################################
#
gsc_log_info "Collect various metrics from the HCP-CS system - ${_prom_proto}://${_prom_name}:${_prom_port}  ${_pdate}"
gsc_log_info "Using metric definition json file: ${_metrics_json_file}"

_current_time_epoch=$(date -u +%s)
_current_time_human=$(date -u -d @${_current_time_epoch} +'%Y-%0m-%0dT%H:%M:%S.%3NZ')
gsc_log_info "Time now (UTC): ${_current_time_human}"

_num_queries=0

##### PROMETHEUS RANGE QUERY INFO ######
# Calculate the start time based on ${_probes_num}, ${_probes_interval} (seconds) and ${_end_time}=${_pdate}
# https://prometheus.io/docs/prometheus/latest/querying/api/#range-queries
# query_range: &start=2024-08-18T20:10:30.781Z&end=2024-08-20T20:11:00.781Z&step=15s
# query: &time=2024-08-18T20:10:30.781Z

if [[ "$(gsc_is_empty "${_pdate}")" == "true" ]]; then
    _end_time_epoch=${_current_time_epoch}
    _end_time=${_current_time_human}
else
    _end_time=${_pdate}
    _end_time_epoch=$(date -d "${_end_time}" +%s)
fi

((_start_time_epoch=_end_time_epoch-((_probes_num-1)*_probes_interval))) # number of probes = ${_probes_num}
_start_time=$(date -u -d @${_start_time_epoch} +'%Y-%0m-%0dT%H:%M:%S.%3NZ')

if [[ "${_probes_enabled}" == "true" ]]; then
    gsc_log_info "Prometheus query range: ${_probes_num} probes with ${_probes_interval} seconds steps"
    gsc_log_info "Query range: start=${_start_time}, end=${_end_time}, step=${_probes_interval}s"
fi

# the timestamp of the oldest metric:
_oldest_date=$(getOldestMetricTimestamp)

if [[ "${_oldest_date}" == "0" ]]; then
    gsc_log_debug "INFO: oldest metric timestamp is not available"
elif [[ "${_forced_proto}" == "false" && ("$(gsc_is_empty "${_oldest_date}")" == "true" || "$(gsc_is_float "${_oldest_date}")" != "true") ]]; then
    gsc_log_debug "FAILED TO GET OLDEST METRIC TIMESTAMP on ${_prom_proto}://${_prom_name}:${_prom_port}"
    if [[ "${_prom_proto}" == "${_default_proto}" ]]; then
        _prom_proto="${_non_default_proto}"
        gsc_log_info "Auto-switching protocol to ${_prom_proto} - collecting from ${_prom_proto}://${_prom_name}:${_prom_port}"
    fi
else
    gsc_log_info "Oldest metric timestamp: ${_oldest_date}"
fi

# Use a specified metrics json file, unless -w is specified for testing from an internal variable
if [[ "${_use_internal_test_metrics}" != "true" ]]; then
    _metric_queries=$(cat "${_metrics_json_file}") # use a specified json file (or default file)
else
    # FOR TESTING - use internal metrics from a variable: $_metric_queries_test (see above) :
    _metric_queries=${_metric_queries_test}
    gsc_log_info "===== TESTING : USING INTERNAL METRIC QUERIES ====="
fi


############### Process all queries in a loop ##############

# Initialize some counters
_blank_query_count=0  # counting blank / empty results
_failed_msg_count=0   # counting failed queries / messages
_msg_count=0          # total useful messages

# Number of metrics:
_num_metrics=$(echo "${_metric_queries}" | jq length)
gsc_log_info "Starting query metrics: ${_num_metrics} queries"

while IFS= read -r _line; do

    ### Increment the count of metrics/queries
    ((_num_queries++))

    gsc_log_debug "============================"

    _event_id=$(echo "$_line" | jq -c '.EventID' | tr -d '"')
    _description=$(echo "$_line" | jq -c '.Description' | tr -d '"')
    _metric_query=$(echo "$_line" | jq -c '.Query' | tr -d '"')
    _warning_criteria=$(echo "$_line" | jq -c '.Warning' | tr -d '"')
    _error_criteria=$(echo "$_line" | jq -c '.Error' | tr -d '"')
    _ignore_criteria=$(echo "$_line" | jq -c '.Ignore' | tr -d '"')
    _label=$(echo "$_line" | jq -c '.Label' | tr -d '"')
    _exclude_label=$(echo "$_line" | jq -c '.Exclude' | tr -d '"')
    _consecutive_probes=$(echo "$_line" | jq -c '.ConsecutiveProbes' | tr -d '"')
    _step=$(echo "$_line" | jq -c '.Step' | tr -d '"')

    # if query contains %PROBESTEP variable - replace it with a specified ${_probes_interval} in seconds
    if [[ "$(echo "${_metric_query}" | grep "%PROBESTEP")" != "" ]]; then
        _metric_query=$(echo "${_metric_query}" | sed "s/%PROBESTEP/${_probes_interval}s/g")
    fi
    # if query contains %THRESHOLD variable - replace it with a specified ${_threshold} in bytes
    if [[ "$(echo "${_metric_query}" | grep "%THRESHOLD")" != "" ]]; then
        _metric_query=$(echo "${_metric_query}" | sed "s/%THRESHOLD/${_threshold}/g")
    fi

    _query_probe_step=$(echo "$_line" | jq -c '.ProbeStep' | tr -d '"')
    _query_start_time=${_start_time}
    if [[ "$(gsc_is_empty "${_query_probe_step}")" == "true" ]]; then
        _query_probe_step=${_probes_interval}
    fi

    gsc_log_debug "[${_num_queries}] ${_description}, Query=${_metric_query}, W: '${_warning_criteria}', E: '${_error_criteria}', Type=${_label}, Exclude:${_exclude_label}"

    if [[ "${_probes_enabled}" == "true" ]]; then
        _metric_result=$(make_query_range "${_metric_query}" "${_query_start_time}" "${_end_time}" "${_query_probe_step}")
    else
        _metric_result=$(make_query "${_metric_query}" "${_pdate}")
    fi
    gsc_log_debug "metric_result=${_metric_result}"

    ### Metric output example:  "16" is the value
    # {"status":"success","data":{"resultType":"vector","result":[{"metric":{},"value":[1611945600.432,"16"]}]}}

    ### Get the "status" field from the result
    _status=$(echo "$_metric_result" | jq -c .status | tr -d '"')

    if [[ "$_status" == "success" ]] ; then

        # Process a query results
        _all_results=$(echo "$_metric_result" | jq -rc '.data.result[]')

        declare -A _msg_details=()
        declare -A _msg_counts=()

        ###################
        # Process results (one value or multiple labels)
        while IFS= read -r _result_json; do

            _skipped_msgs=0  # initialize a counter for skipped messages

            if [[ "$(gsc_is_empty "${_label}")" != "true" ]]; then
                _label_name=$(echo "${_result_json}" | jq -c '.metric.'${_label} | tr -d '"')
            fi

            # If "Exclude" key is specified, then exclude a label that matches $_exclude_label variable
            if [[ "$(gsc_is_empty "${_label_name}")" != "true" && "${_exclude_label}" == "${_label_name}" ]]; then
                gsc_log_debug "Skipping an excluded label: ${_exclude_label}"
                ((_skipped_msgs++))
                spinner # show a progress bar
                continue
            fi

            if [[ "${_probes_enabled}" == "true" ]]; then
                _values_json=$(echo "${_result_json}" | jq -c '.values[]')
            else
                _values_json=$(echo "${_result_json}" | jq -c '.value')
            fi

            # Re-initialize arrays
            _msg_details=()
            _msg_counts=()
            _values=()
            _min=0
            _max=0
            _timestamp_start=$(date -u +%s) # time now
            _timestamp_end=0

            _consecutive_count=0
            _probes=0

            ###################
            # Process one value (single query) or multiple values (range query)
            while IFS= read -r _value_json; do

                ((_probes++))

                _value=$(echo "${_value_json}" | jq -rc '.[1]' | tr -d '"')
                if [[ "$(gsc_is_empty "${_value}")" == "true" || "${_value}" == "NaN" ]]; then
                    # No value - nothing to do
                    ((_blank_query_count++))
                    gsc_log_debug "DEBUG: BLANK QUERY: ${_metric_query}, REPLY: ${_metric_result} , VALUE: '${_value_json}'"
                    continue
                fi

                _timestamp=$(echo "${_value_json}" | jq -rc '.[0]')
                if [[ -n "$(gsc_compare_value "${_timestamp}" ">" "${_timestamp_end}")" ]]; then
                    _timestamp_end=${_timestamp}
                fi

                if [[ -n "$(gsc_compare_value "${_timestamp}" "<" "${_timestamp_start}")" ]]; then
                    _timestamp_start=${_timestamp}
                fi

                ####
                # Check value against a pre-defined warning and error criteria:
                _check_data=$(check_value "${_value}" "${_warning_criteria}" "${_error_criteria}" "${_ignore_criteria}")
                if [[ "${_check_data}" == "" ]]; then
                    # Failed to check
                    ((_failed_msg_count++))
                    gsc_loga "INTERNAL-ERROR: FAILED QUERY: CANNOT PROCESS QUERY: ${_metric_query}, REPLY: ${_metric_result}"
                    continue
                fi

                # Store value in the array
                _values+=("${_value}")

                # Severity level:
                _level=$(echo "${_check_data}" | jq -c '.level' | tr -d '"')

                if [[ "${_probes_enabled}" == "true" && "$(gsc_is_empty "${_consecutive_probes}")" != "true" ]]; then
                    if [[ "$(gsc_is_empty "${_step}")" != "true" && "${_step}" != "${_probes_interval}" ]]; then
                        ((_blank_query_count++))
                        gsc_log_debug "DEBUG: SKIP CONSECUTIVE-TYPE QUERY: ${_metric_query} - it requires step=${_step}"
                        break  # only process this query if steps in the json match the global setting
                    fi
                    spinner

                    if [[ "${_level}" != "INFO" ]]; then
                        # Error or Warning - the condition happened - increment the count
                        ((_msg_counts["${_level}"]++))
                        ((_consecutive_count++))
                    elif [[ "${_consecutive_count}" -ge "${_consecutive_probes}" ]]; then
                        # The condition didn't happen this time, but we already have enough to trigger an alert
                        break
                    else
                        # The condition didn't happen this time, and we don't have enough to trigger an alert => zero the counter
                        _consecutive_count=0
                    fi
                else
                    ((_msg_counts["${_level}"]++))

                    ####
                    # Check if need to skip showing this message
                    #  if level == INFO - show only if verbose mode and Only the first value for the level if multiple probes
                    #  if level != INFO, show only the first value if multiple probes
                    if [[ ! ( ( ("${_level}" == "INFO") && ("${_debug}" != "0") && ("${_msg_counts["INFO"]}" == "1") ) ||
                            ( ("${_level}" != "INFO") && ("${_msg_counts["${_level}"]}" == "1") ) ) ]] ; then

                        ((_skipped_msgs++))
                        spinner # show a progress bar
                        continue
                    fi

                    if [[ "${_level}" != "TELEMETRY" || "${_probes_enabled}" != "true" ]]; then
                        ((_msg_count++))
                        _msg_details["${_level}"]="$(message_format_json_conditional "${_event_id}" "${_description}" "${_check_data}" "${_value_json}" "${_label_name}" "${_label}" )"
                    fi
                fi
            done < <(echo "${_values_json}")


            # If level != INFO and != TELEMETRY and PROBE, report consecutive
            if [[ "$(gsc_is_empty "${_consecutive_probes}")" != "true" && "${_level}" != "INFO" && "${_level}" != "TELEMETRY" && "${_probes_enabled}" == "true" ]]; then
                if [[ "${_consecutive_count}" -ge "${_consecutive_probes}" ]]; then
                    ((_msg_count++))
                    _msg_details["${_level}"]="$(message_format_json_consecutive "${_event_id}" "${_description}" "${_check_data}" "${_consecutive_count}" "${_probes_interval}" "${_label_name}" "${_label}")"
                fi
            fi

            # If level=TELEMETRY and PROBE, report min/max/avg
            if [[ "${_level}" == "TELEMETRY" && "${_probes_enabled}" == "true" ]]; then
                #### Calculate min/max/average for each set of probes
                _value_max=${_values[0]}
                _value_min=${_values[0]}
                _sum=0
                _value_count=0

                for _value in "${_values[@]}"; do
                    if [[ "$(gsc_is_empty "${_value}")" == "true" || "$(gsc_is_float "${_value}")" == "false" ]]; then
                        # No value - nothing to do
                        continue
                    fi
                    ((_value_count++))
                    if [[ -n "$(gsc_compare_value "${_value}" ">" "${_value_max}")" ]]; then
                        _value_max=${_value}
                    fi

                    if [[ -n "$(gsc_compare_value "${_value}" "<" "${_value_min}")" ]]; then
                        _value_min=${_value}
                    fi

                    _sum=$(gsc_arithmetic "${_sum}" "+" "${_value}")
                done

                if (( _value_count > 0 )); then
                    _value_avg=$(gsc_arithmetic "${_sum}" "/" "${#_values[@]}")

                    _value_telem_json='['${_timestamp_start}','${_timestamp_end}',"'${_value_avg}'","'${_value_max}'","'${_value_min}'"]'

                    ((_msg_count++))

                    _msg_details["${_level}"]="$(message_format_json_telem "${_event_id}" "${_description}" "${_check_data}" "${_value_telem_json}" "${_label_name}" "${_label}" )"
                fi
            fi

            ###############
            # Display messages : one msg for each level per label/query
            for _level in "${!_msg_details[@]}"; do
                if [[ "$(gsc_is_empty "${_msg_details["${_level}"]}")" != "true" ]]; then
                    #### Record a message into log file ###
                    gsc_loga "$(message_format_print "${_msg_details["${_level}"]}" "${_msg_counts["${_level}"]}" )"
                fi
            done

        done < <(echo "${_all_results}")

    else
        ### Failed query - record it
        ((_failed_msg_count++))
        gsc_loga "INTERNAL-ERROR: FAILED QUERY: ${_description}: ${_metric_query}, REPLY: ${_metric_result}"
    fi

done < <(echo "${_metric_queries}" | jq -rc '.[] ')

#################
# Final printouts
#

if [[ "${_probes_enabled}" == "true" ]]; then
    gsc_log_info "Collected ${_num_queries} metrics, each with ${_probes_num} probes and ${_probes_interval} seconds step"
else
    gsc_log_info "Collected ${_num_queries} metrics"
fi

gsc_log_info "Generated ${_msg_count} messages"

if [[ "${_failed_msg_count}" != "0" ]]; then
    gsc_log_info "INTERNAL-ERROR: ${_failed_msg_count} failed queries"
fi

if [[ "${_blank_query_count}" != "0" ]]; then
    gsc_log_info "${_blank_query_count} blank queries (metric's value is not available)"
fi

gsc_log_info "Saved results in ${_output_file}"

if [[ "${_use_internal_test_metrics}" == "true" ]]; then
    # FOR TESTING WITH A JSON VARIABLE "$_metric_queries_test (see above) :
    gsc_log_info "===== TESTING : USED INTERNAL METRIC QUERIES ====="
fi

# Calculate time to run
_script_end_time=$(date -u +%s)
((_script_run_seconds=_script_end_time-_current_time_epoch))
gsc_log_info "Total run time: ${_script_run_seconds} sec"
