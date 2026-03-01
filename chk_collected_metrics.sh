#!/usr/bin/env bash
# ========================================================================
# Copyright (c) by Hitachi, 2024. All rights reserved.
# ========================================================================
#
# It collects various metrics from the HCP for Cloud Scale system.
#

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${_script_dir}/gsc_core.sh"

_script_version="0.0.1"
##############################
#
# DEFAULT PARAMETERS:
#
_default_alerts_def_json_file="hcpcs_alerts_def.json"
_default_dir_name="./supportLogs"
_default_output_file_prefix="health_report_metrics"

_default_threshold="1000000000"
_threshold=${_default_threshold}

##########
# Usage
#
usage() {
    local _this_filename
    _this_filename=$(basename "$0")

    echo "\
This script processes telemetry collected from HCP for Cloud Scale or VSP One Object
Version: ${_script_version}
Usage: ${_this_filename} -c <collected-telemetry> [-f <metrics-json-file>] [-o <output-file-prefix>] [-b] [-v info]
e.g. ${_this_filename} -c collected.json
     ${_this_filename} -c collected.json -f hcpcs_alerts_def.json
     ${_this_filename} -c collected.json -f hcpcs_alerts_def.json -o myprefix
     ${_this_filename} -c collected.json -f hcpcs_alerts_def.json -o myprefix -b

${_this_filename} :
  -c <collected-telemetry>  Required    Name of the file with collected telemetry

  -f <alerts-def-file>      Optional    Alerts definition file (default: ${_default_alerts_def_json_file})

  -o <output-file-prefix>   Optional    Output file prefix (default: '${_default_output_file_prefix}')

  -v info                   Optional    Verbose mode: info

  -h                        Optional    This message
"
}

##############################
#
# INPUT PARAMETERS:
#
_prom_name=""    # FQDN or IP address of Prometheus
_pdate=""

_alerts_def_json_file="${_script_dir}/${_default_alerts_def_json_file}"

_use_internal_test_alerts_def="false"

_output_file_prefix=${_default_output_file_prefix}
_dir_name=${_default_dir_name}

_date_suffix=""
_verbose=""
_debug=0

_probes_enabled="true"

_oldest_date_epoch=0  # Prometheus oldest date - epoch time

##############################
#
# Check the input parameters:
#
getOptions() {
    local _opt
    while getopts "c:v:f:q:o:bwh" _opt; do
        case ${_opt} in
            c)  _collected_telemetry_file=${OPTARG}
                ;;

            o)  _output_file_prefix=${OPTARG}
                ;;

            v)  _verbose=${OPTARG}
                ;;

            f)  _alerts_def_json_file=${OPTARG}
                ;;

            b)  _probes_enabled="false"
                ;;

            q)  _threshold=${OPTARG}
                ;;

            w)  _use_internal_test_alerts_def="true"  # hidden option - for internal use only
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
#   $2 - alert definition entry
#
# Output: json string
#   {"SeverityLevel":"ERROR", "AlertCondition":"${_crit_ret}"}
#   {"SeverityLevel":"WARNING", "AlertCondition":"${_warn_ret}"}
#   {"SeverityLevel":"OK", "AlertCondition":"no issues (${_value})"}
#   {"SeverityLevel":"TELEMETRY", "AlertCondition":"(${_telem_ret})" } # telemetry
#
check_value() {
    local _value=$1
    local _alert_def_entry=$2

    local _severity _condition_criteria _ignore_criteria
    _severity=$(echo "${_alert_def_entry}" | jq -c '.Severity' | tr -d '"')
    _condition_criteria=$(echo "${_alert_def_entry}" | jq -c '.Condition' | tr -d '"')
    _ignore_criteria=$(echo "${_alert_def_entry}" | jq -c '.Ignore' | tr -d '"')

    local _ret="" _crit_ret="" _warn_ret="" _telem_ret="" _ignore_ret="" _comment=""
    local _ignore_operator="" _ignore_limit=""
    local _condition_operator="" _condition_limit="" _condition_ret=""

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

    elif [[ "$(gsc_is_empty "${_condition_criteria}")" == "true" ]]; then

        _telem_ret="${_value}"  # report it as a Telemetry if no Condition criteria is specified

    else

        _condition_operator=$(echo "${_condition_criteria}" | awk ' { print $1 } ')
        _condition_limit=$(echo "${_condition_criteria}" | awk ' { print $2 } ')
        _condition_ret=$(compare_value "$_value" "$_condition_operator" "$_condition_limit")
    fi

    if [[ "${_condition_ret}" != "" ]]; then
        _ret='{'
        _ret+='"SeverityLevel":"'${_severity}'","AlertCondition":"'${_condition_ret}'"'
        _ret+='}'
    elif [[ "${_telem_ret}" != "" ]]; then
        _ret='{"SeverityLevel":"TELEMETRY", "AlertCondition":"'${_telem_ret}'"}'
    else
        _ret='{"SeverityLevel":"OK", "AlertCondition":"'${_value}'"}'
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
#  $1: alert_entry
#  $2: check_data_json
#  $3: value_json
#  $4: consecutive_count
#  $5: probe_interval
#  $6: label_key (optional)
#  $7: label_value (optional)
#
# Output:
#      {"AlertID":"<>", "SeverityLevel":"<>", "PriorityLevel":"<>", "ConsecutiveCount":"$3", "ProbeInterval":$4}
#      {"AlertID":"<>", "SeverityLevel":"<>", "PriorityLevel":"<>", "ConsecutiveCount":"$3", "ProbeInterval":$4, "LabelKey":"$5", "LabelValue":"$6"}
#
message_format_json_conditional() {
    local _alert_entry=$1
    local _check_data_json=$2
    local _value_json=$3
    local _consecutive_count=$4
    local _probe_interval=$5
    local _label_key=$6
    local _label_value=$7

    local _alert_id _severity _priority _ticket _frequency _alert_condition _message_json
    _alert_id=$(echo "${_alert_entry}" | jq -c '.AlertID' | tr -d '"')
    _severity=$(echo "${_alert_entry}" | jq -c '.Severity' | tr -d '"')
    _priority=$(echo "${_alert_entry}" | jq -c '.Priority' | tr -d '"')
    _ticket=$(echo "${_alert_entry}" | jq -c '.Ticket' | tr -d '"')
    _frequency=$(echo "${_alert_entry}" | jq -c '.Frequency' | tr -d '"')
    _alert_condition=$(echo "${_check_data_json}" | jq -c '.AlertCondition' | tr -d '"')

    _message_json='{'
    _message_json+='"AlertID":"'${_alert_id}'"'
    _message_json+=',"SeverityLevel":"'${_severity}'","PriorityLevel":"'${_priority}'","SupportTicket":"'${_ticket}'"'
    _message_json+=',"AlertCondition":"'${_alert_condition}'"'

    if [[ "$(gsc_is_empty "${_consecutive_count}")" != "true" ]]; then
        _message_json+=',"ConsecutiveCount":"'${_consecutive_count}'"'
    fi

    if [[ "$(gsc_is_empty "${_value_json}")" != "true" ]]; then
        _message_json+=', "Value":'${_value_json}
    fi

    _message_json+=',"ProbeInterval":"'${_probe_interval}'"'

    if [[ "$(gsc_is_empty "${_frequency}")" != "true" ]]; then
        _message_json+=',"Frequency":"'${_frequency}'"'
    fi

    if [[ "$(gsc_is_empty "${_label_key}")" != "true" ]]; then
        _message_json+=',"LabelKey":"'${_label_key}'", "LabelValue":"'${_label_value}'"'
    fi

    _message_json+='}'
    echo "${_message_json}"
}

###############################
#
# Convert all data for a message into json format - for the Telemetry type
#
#  $1: alertId
#  $2: description
#  $3: check_data
#  $4: message_count
#  $5: value-telemetry-json [timestamp-start, timestamp-end, "avg", "min", "max"]
#  $6: label_key (optional)
#  $7: label_value (optional)
#
# Output:
#    json format:
#      {"AlertID":"$1", "Description":"$2", "AlertDetails":$3, "MessageCount":"$4", "ValueMinMaxAvg":$5}
#      {"AlertID":"$1", "Description":"$2", "AlertDetails":$3, "MessageCount":"$4", "ValueMinMaxAvg":$5, "LabelKey":"$6", "LabelValue":"$7"}
#
message_format_json_telem() {
    local _message_count=$4
    local _value_telem_json=$5
    local _label_key=$6
    local _label_value=$7

    local _message_json
    _message_json='{"AlertID":"'$1'","Description":"'$2'", "AlertDetails":'$3
    _message_json+=',"MessageCount":"'${_message_count}'"'
    _message_json+=', "ValueMinMaxAvg":'${_value_telem_json}

    if [[ "$(gsc_is_empty "${_label_key}")" != "true" ]]; then
        _message_json+=',"LabelKey":"'${_label_key}'", "LabelValue":"'${_label_value}'"'
    fi
    _message_json+='}'
    echo "${_message_json}"
}

###############################
#
# Convert all data for a message into json format - for the Telemetry type
#
#  $1: telemetry_entry
#  $2: query_result (raw prometheus json)
#
# Output:
#    json format:
#      {"TelemetryEntry":$1,"QueryResult":$2}
#
message_format_json_telemetry() {
    local _message_json
    _message_json='{"TelemetryEntry":'$1',"QueryResults":'$2'}'
    echo "${_message_json}"
}

###############################
#
# Parse a message from json format into human-readable format
#
# $1 - alert_entry definition (json)
# $2 - alert details (json)
# $3 - number of messages
# $4 - total number of probes in a query
#
function log_format_human() {
    local _alert_entry=$1
    local _alert_details=$2
    local _msg_count=$3
    local _probes_num_query=$4

    local _alert_id _descr _value_json _consecutive_count _probe_interval
    local _label_key _label_value _value _timestamp _time_info _msg _level _label_info _all _output
    _alert_id=$(echo "${_alert_details}" | jq -rc '.AlertID')
    _descr=$(echo "${_alert_entry}" | jq -rc '.Description')
    _value_json="$(echo "${_alert_details}" | jq -rc '.Value')"
    _consecutive_count="$(echo "${_alert_details}" | jq -rc '.ConsecutiveCount')"
    _probe_interval="$(echo "${_alert_details}" | jq -rc '.ProbeInterval')"
    _label_key=$(echo "${_alert_details}" | jq -rc '.LabelKey')
    _label_value=$(echo "${_alert_details}" | jq -rc '.LabelValue')
    _value=""
    _time_info=""
    _msg=""
    _level=""

    if [[ "$(gsc_is_empty "${_consecutive_count}")" != "true" ]]; then
        _level=$(echo "${_alert_details}" | jq -c '.SeverityLevel' | tr -d '"')
        _msg=$(echo "${_alert_details}" | jq -c '.AlertCondition' | tr -d '"')
        _msg+=" - Consecutive ${_consecutive_count} probes, ${_probe_interval} seconds each"
        _msg_count="${_consecutive_count}"
    elif [[ "$(gsc_is_empty "${_value_json}")" != "true" ]]; then
        _value=$(echo "${_value_json}" | jq -rc '.[1]' | tr -d '"')
        if [[ "${_probes_enabled}" == "true" ]]; then
            _timestamp=$(echo "${_value_json}" | jq -rc '.[0]')
            _time_info=" [$(get_date_format "${_timestamp}")]"
        fi
        _msg=$(echo "${_alert_details}" | jq -c '.AlertCondition' | tr -d '"')
        _level=$(echo "${_alert_details}" | jq -c '.SeverityLevel' | tr -d '"')
    else
        gsc_log_debug "INTERNAL ERROR: message_format_human"
    fi

    _label_info=""
    if [[ "$(gsc_is_empty "${_label_key}")" != "true" && "$(gsc_is_empty "${_label_value}")" != "true" ]]; then
        _label_info=": [${_label_key}=${_label_value}]"
        if [[ "$(gsc_is_empty "${_value}")" != "true" ]]; then
            _label_info+="=${_value}"
        fi
    fi

    # If we got all probes in this query, use the word "all" (for more clarity)
    _all=""
    if [[ "${_msg_count}" == "${_probes_num_query}" ]]; then
        _all="all "
    fi

    # Output format - externally reported
    _output="${_level} : ${_alert_id} : ${_descr} : ${_msg} ${_label_info}${_time_info} [${_all}${_msg_count} probes]"
    echo "${_output}"
}

###############################
#
# Generate json format with the processing results
#
# $1 - alert_entry definition (json)
# $2 - collected raw data from Prometheus (json)
# $3 - alert details (json)
#
log_format_json() {
    local _alert_entry="$1"
    local _collected_entry="$2"
    local _alert_details="$3"

    local _output _condition_criteria _alert_id
    _output="{"
    _condition_criteria=$(echo "${_alert_entry}" | jq -c '.Condition' | tr -d '"')

    if [[ "$(gsc_is_empty "${_condition_criteria}")" != "true" ]]; then
        if [[ "$(gsc_is_empty "${_alert_details}")" != "true" ]]; then
            _output+='"Alert":'${_alert_details}','
            _output+='"AlertDefinition":'${_alert_entry}','
        else
            _alert_id=$(echo "${_alert_entry}" | jq -c '.AlertID' | tr -d '"')
            gsc_log_info "INTERNAL ERROR: missing message details for AlertID ${_alert_id}"
        fi
    else
        _output+='"TelemertyDefinition":'${_alert_entry}','
    fi

    _output+='"CollectedTelemetry":'${_collected_entry}
    _output+="}"
    echo "${_output}"
}

###
# List of Alerts definitions for TESTING - internal-only
#
_alerts_def_test='
[
 {
  "AlertID":"A0010010",
  "TelemetryID":"T001001",
  "Description":"Services uptime status",
  "Severity":"Warning",
  "Priority":"SR3",
  "Ticket":"true",
  "Query":"round(sum by (job) (rate(up {job!~'Metadata-Cache'}[1m])),0.01)+((sum by (job) (up{job!~'Metadata-Cache'})) == bool 0)",
  "Condition":"> 0",
  "Label":"job"
 },
 {
  "AlertID":"A0010020",
  "TelemetryID":"T001002",
  "Description":"Verify if DLS DELETE_BACKEND_OBJECTS is stuck",
  "Severity":"Error",
  "Priority":"SR2",
  "Ticket":"true",
  "Query":"round(delta(lifecycle_policy_examine_latency_seconds_count{policy='DELETE_BACKEND_OBJECTS'}[24h]), 0.01)",
  "Condition":"== 0",
  "Label":"instance",
  "ConsecutiveProbes":"2", "_comments": "must get N=10 consecutive probes that match an Error condition to trigger an alert",
  "Step":"68400",
  "Frequency":"Daily"
 },
 {
  "AlertID":"A0010030",
  "TelemetryID":"T001003",
  "Description":"Verify if DLS DELETE_BACKEND_OBJECTS examine is slow",
  "Severity":"Warning",
  "Priority":"SR2",
  "Ticket":"true",
  "Query":"round(sum(delta(lifecycle_policy_examine_latency_seconds_count{policy='DELETE_BACKEND_OBJECTS'}[24h]))-0.1*(sum(metadata_clientobject_part_active_count)))",
  "Condition":"< 0",
  "ConsecutiveProbes":"2", "_comments": "must get N=2 consecutive probes that match an Error condition to trigger an alert",
  "Step":"68400",
  "Frequency":"Daily"
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

# Validate collected telemetry file
if [[ ! -f ${_collected_telemetry_file} ]]; then
    echo "ERROR: CANNOT FIND ${_collected_telemetry_file}. It is a required parameter"
    exit
fi

# Validate an input Alerts definition json file
if [[ ! -f "${_alerts_def_json_file}" ]]; then
    echo "ERROR: CANNOT FIND ALERTS DEFINITION JSON FILE: ${_alerts_def_json_file}"
    exit
fi

# Alerts definition json file short name (no path, no extension)
_alerts_def_short=$(basename -- "${_alerts_def_json_file%.*}")

# Human-readable output file
_human_output_file="${_output_file_prefix}.log"
[[ -f "${_human_output_file}" ]] && mv "${_human_output_file}" "${_human_output_file}.bak"

# Json output file
_json_output_file="${_output_file_prefix}.json"
[[ -f "${_json_output_file}" ]] && mv "${_json_output_file}" "${_json_output_file}.bak"

# Json pretty output file
_json_pretty_output_file="${_output_file_prefix}_pretty.json"
[[ -f "${_json_pretty_output_file}" ]] && mv "${_json_pretty_output_file}" "${_json_pretty_output_file}.bak"

# Set _output_file so gsc_loga writes to the human-readable log
_output_file="${_human_output_file}"

gsc_log_debug "Input Collected Telemetry: ${_collected_telemetry_file}, Alerts Definition: ${_alerts_def_json_file}  (Verbose: ${_verbose})"

#######################################################################################

################ START #####################################################################################
#
gsc_log_info "Input files: Collected Telemetry: ${_collected_telemetry_file}, Alerts Definition: ${_alerts_def_json_file}"
gsc_log_info "Output files: ${_human_output_file}, ${_json_output_file} and ${_json_pretty_output_file}"

_current_time_epoch=$(date -u +%s)
_current_time_human=$(date -u -d @${_current_time_epoch} +'%Y-%0m-%0dT%H:%M:%S.%3NZ')
gsc_log_info "Time now (UTC): ${_current_time_human}"

_num_queries=0

#
# Get header values from the Collected-Telemetry file
#
# {"SystemName":"b1-20", "Port":"9096","StartTime":"2024-09-04T09:00:00.000Z","EndTime":"2024-09-04T10:00:00.000Z","Step":"360", "Telemetry":[]}
_collected_telemetry=$(cat "${_collected_telemetry_file}")
_system_name=$(echo "${_collected_telemetry}" | jq -c '.SystemName' | tr -d '"')
_start_time=$(echo "${_collected_telemetry}" | jq -c '.StartTime' | tr -d '"')
_end_time=$(echo "${_collected_telemetry}" | jq -c '.EndTime' | tr -d '"')
_step=$(echo "${_collected_telemetry}" | jq -c '.Step' | tr -d '"')
_probes_num=$(echo "${_collected_telemetry}" | jq -c '.Probes' | tr -d '"')

if [[ $(gsc_is_empty "${_probes_num}") == "true" ]]; then
    _probes_num="60" # default
fi

_all_collected_entries=$(echo "${_collected_telemetry}" | jq -c '.Telemetry')

if [[ "${_probes_enabled}" == "true" ]]; then
    gsc_log_info "Probes Enabled: ${_probes_num} probes with ${_step} seconds steps"
    gsc_log_info "Query range: start=${_start_time}, end=${_end_time}, step=${_step}"
fi

# Use a specified metrics json file, unless -w is specified for testing from an internal variable
if [[ "${_use_internal_test_alerts_def}" != "true" ]]; then
    _alerts_def=$(cat "${_alerts_def_json_file}") # use a specified json file (or default file)
else
    # FOR TESTING - use internal metrics from a variable: $_alerts_def_test (see above) :
    _alerts_def=${_alerts_def_test}
    gsc_log_info "===== TESTING : USING INTERNAL ALERTS DEFINITIONS ====="
fi


############### Process all collected telemetry records in a loop ##############

# Initialize some counters
_blank_query_count=0  # counting blank / empty results
_failed_msg_count=0   # counting failed queries / messages
_msg_count=0          # total useful messages
_telemetry_count=0    # total telemetry records

# Number of metrics:
_num_alerts_def=$(echo "${_alerts_def}" | jq length)
_num_collected_records=$(echo "${_all_collected_entries}" | jq length)
gsc_log_info "Starting processing: ${_num_collected_records} collected records - using ${_num_alerts_def} alerts definitions"

while IFS= read -r _alert_entry; do

    ### Increment the count of metrics/queries
    ((_num_queries++))

    gsc_log_debug "============================"

    _alert_id=$(echo "${_alert_entry}" | jq -c '.AlertID' | tr -d '"')
    _description=$(echo "${_alert_entry}" | jq -c '.Description' | tr -d '"')
    _telemetry_id=$(echo "${_alert_entry}" | jq -c '.TelemetryID' | tr -d '"')
    _step_query=$(echo "${_alert_entry}" | jq -c '.Step' | tr -d '"')
    _probes_num_query=$(echo "${_alert_entry}" | jq -c '.Probes' | tr -d '"')

    if [[ "$(gsc_is_empty "${_step_query}")" == "true" ]]; then
        _step_query="${_step}"
    fi

    if [[ "$(gsc_is_empty "${_probes_num_query}")" == "true" ]]; then
        _probes_num_query="${_probes_num}"
    fi

    # Get the query results by Telemetry ID (ignore duplicates, if any)
    _collected_entry=$(echo "${_all_collected_entries}" | jq -rc --arg TELEMETRYID "$_telemetry_id" 'first(.[] | select(.TelemetryID==$TELEMETRYID))')

    _query_result=$(echo "${_collected_entry}" | jq -c '.Prometheus')
    if [[ $(gsc_is_empty "$_query_result") == "true" ]]; then
        gsc_log_info "INTERNAL ERROR: Skipping - no results for ${_telemetry_id} (AlertID: ${_alert_id})"
        continue
    else
        gsc_log_debug "query_result=${_query_result}"
    fi

    _severity=$(echo "${_alert_entry}" | jq -c '.Severity' | tr -d '"')
    _priority=$(echo "${_alert_entry}" | jq -c '.Priority' | tr -d '"')
    _ticket=$(echo "${_alert_entry}" | jq -c '.Ticket' | tr -d '"')

    _condition_criteria=$(echo "${_alert_entry}" | jq -c '.Condition' | tr -d '"')

    _ignore_criteria=$(echo "${_alert_entry}" | jq -c '.Ignore' | tr -d '"')
    _label_key=$(echo "${_alert_entry}" | jq -c '.Label' | tr -d '"')
    _exclude_label_value=$(echo "${_alert_entry}" | jq -c '.Exclude' | tr -d '"')
    _consecutive_limit=$(echo "${_alert_entry}" | jq -c '.ConsecutiveProbes' | tr -d '"')

    gsc_log_debug "[${_num_queries}] ${_alert_id} : ${_telemetry_id} : Description: '${_description}'"
    gsc_log_debug "[${_num_queries}] ${_alert_id} : ${_description} : Condition: '${_condition_criteria}', Ignore: '${_ignore_criteria}', Type=${_label_key}, Exclude:${_exclude_label_value}"
    gsc_log_debug "query_result=${_query_result}"

    if [[ "$(gsc_is_empty "${_condition_criteria}")" == "true" ]]; then
        # If Condition field is not specified, it means it's Telemetry entry - just record it, don't process

        ((_telemetry_count++))
        # Save ${_collected_entry} - it includes all results

        # raw json format
        _output_json=$(log_format_json "${_alert_entry}" "${_collected_entry}")
        printf '%s\n' "${_output_json}" >> "${_json_output_file}"
        # pretty json format
        _output_json_pretty=$(echo "${_output_json}" | jq . )
        printf '%s\n' "${_output_json_pretty}" >> "${_json_pretty_output_file}"

        continue
    fi

    ### Metric output example:  "16" is the value
    # {"status":"success","data":{"resultType":"vector","result":[{"metric":{},"value":[1611945600.432,"16"]}]}}

    ### Get the "status" field from the result
    _status=$(echo "$_query_result" | jq -c .status | tr -d '"')

    if [[ "$_status" == "success" ]] ; then

        # Process a query results
        _all_results=$(echo "$_query_result" | jq -rc '.data.result[]')

        if [[ "$(gsc_is_empty "${_all_results}")" == "true" ]]; then
            ((_blank_query_count++))
            gsc_log_debug "DEBUG: BLANK QUERY: ${_alert_id} : ${_telemetry_id} : ${_description}"
            continue
        fi

        declare -A _alert_details=()
        declare -A _matched_condition_counts=()

        ###################
        # Process results (one value or multiple labels)
        while IFS= read -r _result_json; do

            _skipped_msgs=0  # initialize a counter for skipped messages

            if [[ "$(gsc_is_empty "${_label_key}")" != "true" ]]; then
                _label_value=$(echo "${_result_json}" | jq -c '.metric.'${_label_key} | tr -d '"')
            fi

            # If "Exclude" key is specified, then exclude a label that matches $_exclude_label_value variable
            if [[ "$(gsc_is_empty "${_label_value}")" != "true" && "${_exclude_label_value}" == "${_label_value}" ]]; then
                gsc_log_debug "Skipping an excluded label: ${_exclude_label_value}"
                ((_skipped_msgs++))
                spinner
                continue
            fi

            if [[ "${_probes_enabled}" == "true" ]]; then
                _values_json=$(echo "${_result_json}" | jq -c '.values[]')
            else
                _values_json=$(echo "${_result_json}" | jq -c '.value')
            fi

            # Re-initialize arrays
            _alert_details=()
            _matched_condition_counts=()
            _values=()
            _min=0
            _max=0
            _timestamp_start=$(date -u +%s) # time now
            _timestamp_end=0

            _consecutive_count=0
            _consecutive_check_data=""
            _check_data=""
            _probes=0

            ###################
            # Process one value (single query) or multiple values (range query)
            while IFS= read -r _value_json; do

                ((_probes++))
                spinner

                _value=$(echo "${_value_json}" | jq -rc '.[1]' | tr -d '"')
                if [[ "$(gsc_is_empty "${_value}")" == "true" || "${_value}" == "NaN" ]]; then
                    # No value - nothing to do
                    ((_blank_query_count++))
                    gsc_log_debug "DEBUG: BLANK QUERY: ${_alert_id} ${_telemetry_id} ${_description}, REPLY: ${_query_result} , VALUE: '${_value_json}'"
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
                # Check value against a pre-defined criteria:
                _check_data=$(check_value "${_value}" "${_alert_entry}")
                if [[ "${_check_data}" == "" ]]; then
                    # Failed to check
                    ((_failed_msg_count++))
                    gsc_loga "INTERNAL-ERROR: FAILED QUERY: CANNOT PROCESS QUERY: ${_alert_id} ${_telemetry_id} ${_description}, REPLY: ${_query_result}"
                    continue
                fi

                # Store value in the array
                _values+=("${_value}")

                # Severity level:
                _level=$(echo "${_check_data}" | jq -c '.SeverityLevel' | tr -d '"')

                if [[ "${_probes_enabled}" == "true" && "$(gsc_is_empty "${_consecutive_limit}")" != "true" ]]; then

                    if [[ "${_level}" != "OK" ]]; then
                        # Error or Warning - the condition was matched - increment the count
                        ((_matched_condition_counts["${_level}"]++))
                        ((_consecutive_count++))
                        _consecutive_check_data="${_check_data}"  # preserve check_data with a matching condition for the reporting
                    elif [[ "${_consecutive_count}" -ge "${_consecutive_limit}" ]]; then
                        # The condition didn't happen this time, but we already have enough to trigger an alert
                        break
                    else
                        # The condition didn't happen this time, and we don't have enough to trigger an alert => zero the counter
                        _consecutive_count=0
                    fi
                else
                    ((_matched_condition_counts["${_level}"]++))

                    ####
                    # Check if need to skip showing this message
                    #  if level == OK - show only if verbose DEBUG mode and Only the first value for the level if multiple probes
                    #  if level != OK - show only the first value if multiple probes
                    if [[ ! ( ( ("${_level}" == "OK") && ("${_debug}" == "2") && ("${_matched_condition_counts["OK"]}" == "1") ) ||
                            ( ("${_level}" != "OK") && ("${_matched_condition_counts["${_level}"]}" == "1") ) ) ]] ; then
                        ((_skipped_msgs++))
                        continue
                    fi

                    ((_msg_count++))

                    _alert_details["${_level}"]="$(message_format_json_conditional "${_alert_entry}" \
                                                                           "${_check_data}" "${_value_json}" "null" \
                                                                           "${_step_query}" \
                                                                           "${_label_key}" "${_label_value}" )"
                fi
            done < <(echo "${_values_json}")

            if [[ "${_probes_enabled}" == "true" && "$(gsc_is_empty "${_consecutive_limit}")" != "true" && ("${_consecutive_count}" -ge "${_consecutive_limit}") ]]; then
                ((_msg_count++))

                _level="${_severity}"
                _alert_details["${_level}"]="$(message_format_json_conditional "${_alert_entry}" \
                                                                           "${_consecutive_check_data}" "null" "${_consecutive_count}" \
                                                                           "${_step_query}" "${_label_key}" "${_label_value}")"
                gsc_log_debug "${_alert_id}: Consecutive: ${_consecutive_count} : ${_alert_details["${_level}"]}"
            fi

            # If level=TELEMETRY and PROBE, report min/max/avg
            if [[ "${_level}" == "TELEMETRY" ]]; then
                #### Calculate min/max/average for each set of probes
                _value_max=${_values[0]}
                _value_min=${_values[0]}
                _sum=0
                _value_count=0

                gsc_log_info "INTERNAL ERROR: Unexpected Telemetry: ${_alert_id} : ${_level} : ${_description}"

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

                if (( ${_value_count} > 0 )); then
                    _value_avg=$(gsc_arithmetic "${_sum}" "/" "${#_values[@]}")

                    _value_telem_json='['${_timestamp_start}','${_timestamp_end}',"'${_value_avg}'","'${_value_max}'","'${_value_min}'"]'

                    ((_msg_count++))

                    gsc_log_info "INTERNAL ERROR: Unexpected Telemetry: ${_alert_id} : ${_msg_count} : ${_level} : ${_description}"

                    _alert_details["${_level}"]="$(message_format_json_telem "${_alert_id}" "${_description}" "${_check_data}" \
                                                                         "${_matched_condition_counts["${_level}"]}" "${_value_telem_json}" \
                                                                         "${_label_key}" "${_label_value}" )"
                fi
            fi

            ###############
            # Display messages : one msg for each level per label/query
            for _level in "${!_alert_details[@]}"; do
                if [[ "$(gsc_is_empty "${_alert_details["${_level}"]}")" != "true" ]]; then
                    #### Record an alert details message into the log files ###

                    # human-readable output
                    gsc_loga "$(log_format_human "${_alert_entry}" "${_alert_details["${_level}"]}" "${_matched_condition_counts["${_level}"]}" "${_probes_num_query}")"

                    # raw json format
                    _output_json=$(log_format_json "${_alert_entry}" "${_collected_entry}" "${_alert_details["${_level}"]}" )
                    printf '%s\n' "${_output_json}" >> "${_json_output_file}"

                    # pretty json format
                    _output_json_pretty=$(echo "${_output_json}" | jq . )
                    printf '%s\n' "${_output_json_pretty}" >> "${_json_pretty_output_file}"

                fi
            done

        done < <(echo "${_all_results}")

    else
        ### Failed query - record it
        ((_failed_msg_count++))
        gsc_loga "INTERNAL-ERROR: FAILED QUERY: ${_alert_id} ${_telemetry_id} : ${_description} status=${_status} REPLY: ${_query_result}"
    fi

done < <(echo "${_alerts_def}" | jq -rc '.[] ')

#################
# Final printouts
#

gsc_log_info "Processed ${_num_collected_records} records - using ${_num_queries} definitions, including ${_telemetry_count} telemetry definitions"
gsc_log_info "Generated ${_msg_count} alerts"

if [[ "${_failed_msg_count}" != "0" ]]; then
    gsc_log_info "INTERNAL-ERROR: ${_failed_msg_count} failed queries"
fi

if [[ "${_blank_query_count}" != "0" ]]; then
    gsc_log_info "${_blank_query_count} blank queries (metric's value is not available)"
fi

gsc_log_info "Saved results in ${_human_output_file}, ${_json_output_file} and ${_json_pretty_output_file} files"

if [[ "${_use_internal_test_alerts_def}" == "true" ]]; then
    # FOR TESTING WITH A JSON (option -w see above)
    gsc_log_info "===== TESTING : USED INTERNAL ALERTS DEFINITIONS ====="
fi

# Calculate time to run
_script_end_time=$(date -u +%s)
((_script_run_seconds=_script_end_time-_current_time_epoch))
gsc_log_info "Total run time: ${_script_run_seconds} sec"
