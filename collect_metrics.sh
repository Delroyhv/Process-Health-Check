#!/bin/bash
# ========================================================================
# Copyright (c) by Hitachi, 2024. All rights reserved.
# ========================================================================
#
# It collects various metrics from the HCP for Cloud Scale system.
#
SCRIPT_VERSION="0.0.1"
##############################
#
# DEFAULT PARAMETERS:
#
DEFAULT_INPUT_COLLECTION_JSON_FILE="hcpcs_collection_def_autogen.json"
DEFAULT_PORT="9191"
DEFAULT_DIR_NAME="./supportLogs"

HTTP_STRING="http"
HTTPS_STRING="https"
DEFAULT_PROTO=${HTTPS_STRING}
NON_DEFAULT_PROTO=${HTTP_STRING}

DEFAULT_PROBES_INTERVAL=300  # in seconds
DEFAULT_PROBES_NUM=24 
MAX_PROBES_NUM=4000 # avoid too many probes to process (may need to adjust the MAX)

DEFAULT_OUTPUT_FILE_PREFIX="health_report_metrics"
FORCED_PROTO="false"

DEFAULT_THRESHOLD="1000000000"

THRESHOLD=${DEFAULT_THRESHOLD}

AUTHENTICATE="false"
USERNAME="admin"
PASSWD="start123!"

##########
# Usage
# 
function usage() {
    thisfilename=$(basename "$0")

    echo "\
This script collects various metrics from HCP for Cloud Scale cluster.
Version: ${SCRIPT_VERSION}
Usage: $thisfilename -c <prometheus-fqdn> [-n <port>] [-t <date>] [-s <http-proto>] [-f <metrics-json-file>] [-o <output-file-prefix>] [-v info]
e.g. $thisfilename -c hcpcs.example.com
     $thisfilename -c hcpcs.example.com -t 2024-08-19T20:10:30.781Z -i 600 -e 120
     $thisfilename -c hcpcs.example.com -n 9090 -s http -t 2024-08-19T20:10:30.781Z 
     $thisfilename -c hcpcs.example.com -n 9095 -f my_metrics.json -v info

$thisfilename :
  -c <prometheus>           Required    FQDN or IP address of Prometheus, optionally with a port number

  -n <port>                 Optional    Port number (default: ${DEFAULT_PORT}) 

  -t <date>                 Optional    Date and time in the following format: '2024-08-19T20:10:30.781Z'
                                        default is the current time (now)

  -f <collection-def-json>  Optional    File with a list of metrics (default: ${DEFAULT_INPUT_COLLECTION_JSON_FILE})

  -b                        Optional    Disables probes mode (switches to a single-query mode)

  -e <number-probes>        Optional    Number of probes (default: ${DEFAULT_PROBES_NUM})

  -i <probes-interval>      Optional    Interval between the probes in seconds (default: ${DEFAULT_PROBES_INTERVAL} sec)

  -s <http-protocol>        Optional    http or https (default: https)

  -p <output-file-prefix>   Optional    Output file prefix (default: '${DEFAULT_OUTPUT_FILE_PREFIX}')

  -u <username:password>    Optional    User name and optionally password (when required)

  -o <output-file>          Optional    Output file (if -o is specified, -p is ignored)

  -v info                   Optional    Verbose mode: info

  -h                        Optional    This message
"
}

##############################
#
# INPUT PARAMETERS:
#

PROM_PROTO=${DEFAULT_PROTO}
PROM_NAME=""    # FQDN or IP address of Prometheus
PROM_PORT=${DEFAULT_PORT}
PDATE="" 


USE_INTERNAL_TEST_METRICS="false"
SCRIPT_DIR=$(dirname $0)
METRICS_JSON_FILE=${SCRIPT_DIR}/${DEFAULT_INPUT_COLLECTION_JSON_FILE}

OUTPUT_FILE_PREFIX=${DEFAULT_OUTPUT_FILE_PREFIX}
DIR_NAME=${DEFAULT_DIR_NAME}

DATE_SUFFIX=""
VERBOSE=""
DEBUG=0
AUTH=()

PROBES_ENABLED="true"
PROBES_INTERVAL=${DEFAULT_PROBES_INTERVAL} # in seconds
PROBES_NUM=${DEFAULT_PROBES_NUM}

oldest_date_epoch=0  # Prometheus oldest date - epoch time

##############################
#
# Check the input parameters:
#
function getOptions() {
    while getopts "c:d:v:f:o:p:e:i:n:q:m:t:u:s:bwh" opt; do
        case $opt in
            c)  PROM_NAME=${OPTARG}
                ;;

            o)  OUTPUT_FILE=${OPTARG}
                ;;

            p)  OUTPUT_FILE_PREFIX=${OPTARG}
                ;;

            u)  USERNAME_PASSWD=${OPTARG}
                AUTHENTICATE="true"
                ;;

            v)  VERBOSE=${OPTARG}
                ;;

            f)  METRICS_JSON_FILE=${OPTARG}
                ;;

            n)  PROM_PORT=${OPTARG}
                ;;

            b)  PROBES_ENABLED="false"
                ;;

            e)  PROBES_NUM=${OPTARG}
                ;;

            m)  MAX_PROBES_NUM=${OPTARG} # adjust MAX_PROBES_NUM - hidden option
                ;;

            i)  PROBES_INTERVAL=${OPTARG}
                ;;

            t)  PDATE=${OPTARG}
                ;;

            q)  THRESHOLD=${OPTARG}
                ;;

            s)  PROM_PROTO=${OPTARG}
                FORCED_PROTO="true"
                ;;

            w)  USE_INTERNAL_TEST_METRICS="true"  # hidden option - for internal use only
                ;;

            *)  usage
                exit 0
                ;;
        esac
    done
}


##############################
# Checks if a variable is empty
#
# Input: 
#    $1 - variable to examine
#
# Output:
#    true - if variable is empty
#    false - variable is not empty
# 
function isEmpty() {
   ret="false"
   if [[ -z "$1" || $1 == null || "$1" == "" ]]; then
      ret="true"
   fi
   echo "$ret"
}

##############################
#
# Check if a variable is a number
#
function isNumber() {
  ret="false"

  re='^[0-9]+$'
  if [[ $1 =~ $re ]] ; then
      ret="true"
  fi
  echo "$ret"
}

##############################
#
# Check if a variable is a floating number
#
function isFloatNumber() {
  ret="false"

  re='^[0-9]+([.][0-9]+)?$'
  if [[ $1 =~ $re ]] ; then
      ret="true"
  fi
  echo "$ret"
}

###############################
#
# Display to stdout and save into log file
#
function loga() {
    echo "$1" | tee -a ${OUTPUT_FILE}
}

###############################
#
# Save into log file
#
function log() {
    echo "$1" >> ${OUTPUT_FILE}
}

###############################
#
# Display to stdout
#
function display() {
    echo "$1"
}

###############################
#
# Verbose DEBUG mode output
#
function debug() {
    if [[ "${DEBUG}" == "2" ]] ; then
        echo -e "$1" 
    fi
}

###############################
#
# Verbose INFO mode output
#
function info() {
    if [[ "${DEBUG}" == "1" ]] ; then
        echo -e "$1"
    fi
}


sii=0
###############################
#
# Display a spinner
#
function spinner() {

spin[0]="-"
spin[1]="\\"
spin[2]="|"
spin[3]="/"

  ((sii++))
  num=$(($sii%4))
  echo -ne "${spin[${num}]} \r" >&2
}

###############################
#
# Validate and set the output log file
#
function setLogFile() {
    output_fname="$1"
    # append ".log" if it's not specified
    if [[ "$1" != *".log" ]]; then
       output_fname="$1.log"
    fi
    OUTPUT_FILE="${output_fname}"

    if [[ -f ${OUTPUT_FILE} ]]; then
        mv ${OUTPUT_FILE} ${OUTPUT_FILE}.bak
    fi
}

###
# List of metric queries for TESTING - internal-only 
#
metric_queries_test='
[
 {
  "TelemetryID":"TT000001",
  "Description":"DB Partitions per node limit",
  "Query":"(max(mcs_partitions_per_instance))"
 },
 {
  "TelemetryID":"TT000002",
  "Description":"DB used capacity in bytes (per node)", 
  "Query":"metadata_used_capacity_bytes"
 },
 {
  "TelemetryID":"TT000003",
  "Description":"DB used capacity percentage (incl. aggregate)",
  "Query":"round(100*((topk(1, metadata_used_capacity_bytes) by (store)) / on (store) (topk(1, metadata_used_capacity_bytes+metadata_available_capacity_bytes) by (store))))"
 },
 {
  "TelemetryID":"TT000004", 
  "Description":"DB used capacity percentage (per node)",
  "Query":"round(100*((topk(1, metadata_used_capacity_bytes) by (store)) / on (store) (topk(1, metadata_used_capacity_bytes+metadata_available_capacity_bytes) by (store))))"
 },
 {
  "TelemetryID":"TT000005",
  "Description":"Verify if DLS VERSION_EXPIRATION is stuck",
  "Query":"round(delta(lifecycle_policy_examine_latency_seconds_count{policy='VERSION_EXPIRATION'}[%PROBESTEP]), 0.01)"
 },
 {
  "TelemetryID":"TT010003",
  "Description":"Verify if DLS DELETE_BACKEND_OBJECTS examine is slow",
  "Query":"round(sum(delta(lifecycle_policy_examine_latency_seconds_count{policy='DELETE_BACKEND_OBJECTS'}[24h]))-0.1*(sum(metadata_clientobject_part_active_count)))",
  "Step":"68400",
  "Probes":"7",
  "Frequency":"Daily"
 },
 {
  "TelemetryID":"TT000006",
  "Description":"DLS DELETE_BACKEND_OBJECTS error rate for General category is >10% for at least 10 min",
  "Query":"round(sum(delta(lifecycle_policy_errors_total{category='General', policy='DELETE_BACKEND_OBJECTS'}[%PROBESTEP])))"
  "Step":"60"
 }
]'

####################### INITIALIZATION ###############
#

getOptions "$@"


##### Validate input parameters ######
#
# Used for date validation (the date must be after 2020)
TEST_EPOCH_TIME="1600000000" # September 13, 2020

if [[ "${VERBOSE}" == "info" ]]; then
    DEBUG=1
elif [[ "${VERBOSE}" == "debug" ]]; then
    DEBUG=2
elif [[ "${VERBOSE}" == "" ]]; then
    DEBUG=0
else 
    echo "ERROR: Invalid verbose mode: $VERBOSE - if specified, must be either 'info' or 'debug'"
    exit
fi

if [[ "$(isEmpty "${USERNAME_PASSWD}")" != "true" ]]; then
    passwd_separator=$(echo "${USERNAME_PASSWD}" | grep -c ":")
    if [[ "${passwd_separator}" == "1" ]]; then
        USERNAME=$(echo "${USERNAME_PASSWD}" | awk -F':' '{ print $1 }')
        PASSWD=$(echo "${USERNAME_PASSWD}" | awk -F':' '{ print $2 }')
        AUTH=(-u "$USERNAME:$PASSWD")
    else
        USERNAME="${USERNAME_PASSWD}"
        AUTH=(-u "$USERNAME")
    fi
fi


# Validate Prometheus FQDN name
if [[ "${PROM_NAME}" == "" ]]; then
    echo "ERROR: Prometheus node name or IP is a required parameter"
    exit
fi

# Validate the date format
if [[ "$(isEmpty ${PDATE})" != "true" ]]; then
    pdate_epoch=$(date -d "${PDATE}" +%s)
    if [[ "$(isNumber ${pdate_epoch})" != "true" ]]; then
        echo "ERROR: DATE FORMAT IS INCORRECT: ${PDATE} (expected format: 2024-08-19T20:10:30.781Z)"
        exit
    elif [[ "${pdate_epoch}" -lt "${TEST_EPOCH_TIME}" ]]; then
        echo "ERROR: DATE IS TOO OLD: ${PDATE} (expected after 2020)"
        exit    
    fi

    pdate_epoch=$(date -u -d "${PDATE}" +%s)
    DATE_SUFFIX="$(date -u -d @${pdate_epoch} +'%Y%b%d_%H%M%S%Z')"
fi

# Validate an input metrics json file
if [[ ! -f "${METRICS_JSON_FILE}" ]]; then
    echo "ERROR: CANNOT FIND METRICS JSON FILE: ${METRICS_JSON_FILE}"
    exit
fi

# Validate protocol (it must be either http or https)
if [[ "${PROM_PROTO}" != "" && "${PROM_PROTO}" != "${HTTPS_STRING}" && ${PROM_PROTO} != "${HTTP_STRING}" ]]; then
    echo "ERROR: INVALID PARAMETER -s (${PROM_PROTO})"
    exit
fi

# Validate a probe interval (in seconds)
if [[ "$(isNumber ${PROBES_INTERVAL})" != "true" ]]; then
    echo "ERROR: probes interval (in seconds) must be an integer number (${PROBES_INTERVAL})"
    exit
fi

# Validate a number of probes (number of values in each metric request)
if [[ "$(isNumber ${PROBES_NUM})" != "true" ]]; then
    echo "ERROR: number of probes must be an integer number (${PROBES_NUM})"
    exit
fi

# Safety net - the number of probes shouldn't be too high - a number of values returned by each metric request
# If PROBES_NUM is too high, it'll take a long time to collect and process it
if (( ${PROBES_NUM} > ${MAX_PROBES_NUM} )); then
    echo "ERROR: number of probes must be equal or less than ${MAX_PROBES_NUM} (${PROBES_NUM} is too high)"
    exit
fi

# Metrics json file short name (no path, no extention)
METRICS_JSON_SHORT=$(basename -- "${METRICS_JSON_FILE%.*}")

# Set the output log file
if [[ "${OUTPUT_FILE}" == "" ]] ; then
    if [[ "${PROM_PORT}" == "${DEFAULT_PORT}" ]]; then
        OUTPUT_FILE="${OUTPUT_FILE_PREFIX}_${PROM_NAME}_${METRICS_JSON_SHORT}_${DATE_SUFFIX}.log"
    else 
        OUTPUT_FILE="${OUTPUT_FILE_PREFIX}_${PROM_NAME}_${PROM_PORT}_${METRICS_JSON_SHORT}_${DATE_SUFFIX}.log"
    fi
fi

if [[ -f ${OUTPUT_FILE} ]]; then
    mv ${OUTPUT_FILE} ${OUTPUT_FILE}.bak
fi

debug "Prometheus: ${PROM_PROTO}://${PROM_NAME}:${PROM_PORT}   Date: '${PDATE}'  Verbose: ${VERBOSE}"


#######################################################################################

############################
# Make Prometheus query (single value)
# 
# Input:
#     ${PROM_NAME} - FQDN or IP of Prometheus service
#     ${PROM_PORT} - port number of Prometheus service
# 
#     $1 - prometheus query
#     $2 - date in the following format (2024-06-02T05:10:30.781Z) 
#             or empty for the current time
#
# Output:
#     reply from Prometheus in json format
#
function make_query() {
  
   metric=$1
   pdate=$2

   ### Convert query to to URL encoding
   urlenc_metric=$(echo "$metric" | jq -sRr @uri)

   if [[ "${pdate}" != "" ]]; then
       urlenc_metric+="&time=$pdate"
   fi

   ### Form the query command (curl)
   mycmd=(curl "${AUTH[@]}" -s -k -X GET "${PROM_PROTO}://${PROM_NAME}:${PROM_PORT}/api/v1/query?query=${urlenc_metric}")
   if [[ "${DEBUG}" == "2" ]]; then
       echo "mycmd=${mycmd[*]}" >&2
   fi

   ### Run the query command on Prometheus:
   result=$("${mycmd[@]}")
   #debug "query result=${result}"

   echo "${result}"
}

############################
# Make Prometheus query_range (multiple values)
# 
# Input:
#     ${PROM_NAME} - FQDN or IP of Prometheus service
#     ${PROM_PORT} - port number of Prometheus service
# 
#     $1 - prometheus query
#     $2 - start timestamp - date/time in the following format (2024-06-02T05:10:30.781Z) 
#     $3 - end timestamp - date/time in the following format (2024-06-02T05:10:30.781Z)  
#     $4 - step (in seconds)
#
# Output:
#     reply from Prometheus in json format
#
function make_query_range() {
  
   metric=$1
   start=$2
   end=$3
   step=$4

   ### Convert query to to URL encoding
   urlenc_metric=$(echo "$metric" | jq -sRr @uri)

   if [[ "${start}" == "" || "${end}" == "" || "${step}" == "" ]]; then
       echo "INTERNAL ERROR: MISSING INPUT PARAMETERS FOR QUERY_RANGE ENDPOINT (&start=$start&end=$end&step=$step)" >&2
       exit
   fi
  
   urlenc_metric+="&start=${start}&end=${end}&step=${step}s"

   ### Form the query command (curl)
   mycmd=(curl "${AUTH[@]}" -s -k -X GET "${PROM_PROTO}://${PROM_NAME}:${PROM_PORT}/api/v1/query_range?query=${urlenc_metric}")

   if [[ "${DEBUG}" == "2" ]]; then
       echo "mycmd=${mycmd[*]}" >&2
   fi

   ### Run the query command on Prometheus:
   result=$("${mycmd[@]}")
   #debug "query result=${result}"

   echo "${result}"
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
function get_date_format() {
    echo "$(date -u -d @$1 +'%Y-%0m-%0dT%H:%M:%SZ')"
}

#############################
#
# Get Olderest metric from Prometheus DB snapshot
#
# Output:
#    timestamp   if success (e.g. 2024-08-19T20:10:30.781Z)
#    "0"         if Prometheus query is successful but a value is not returned
#    ""          empty, if Prometheus query failed
#
function getOldestMetricTimestamp() {

    err=0
    oldest_date=""
    description="Timestamp of the oldest metric in Prometheus DB"
    query="prometheus_tsdb_lowest_timestamp_seconds"
 
    debug "${description}, Query=${query}"
   
    query_result=$(make_query "${query}" "")
    debug "query_result=${query_result}"

    ### Metric output example:  "16" is the value
    # {"status":"success","data":{"resultType":"vector","result":[{"metric":{},"value":[1611945600.432,"16"]}]}}

    ### Get the "status" field from the result
    status=$(echo "$query_result" | jq -c .status | tr -d '"')
    if [[ "$status" == "success" ]] ; then

        ### Process successful query result
        oldest_date_epoch=$(echo "$query_result" | jq -c .data.result[0].value[1] | tr -d '"')
        if [[ "$(isEmpty ${oldest_date_epoch})" == "true" ]]; then
            debug "BLANK QUERY: getOldestMetricTimestamp: ${metric_query}, REPLY: ${query_result}"
            err=1
            oldest_date="0"
        fi
    else

        ### Failed query - record it
        debug "FAILED QUERY: getOldestMetricTimestamp: ${metric_query}, REPLY: ${query_result}"
        err=2
    fi

    if [[ "${err}" == "0" ]]; then
        oldest_date=$(get_date_format ${oldest_date_epoch})
    fi

    echo "${oldest_date}"
}

################ START #####################################################################################
#
display "Collect various metrics from the HCP-CS system - ${PROM_PROTO}://${PROM_NAME}:${PROM_PORT}  ${PDATE}"
display "Using metric definition json file: ${METRICS_JSON_FILE}"

current_time_epoch=$(date -u +%s)
current_time_human=$(date -u -d @${current_time_epoch} +'%Y-%0m-%0dT%H:%M:%S.%3NZ')
display "Time now (UTC): ${current_time_human}"

num_queries=0

##### PROMETHEUS RANGE QUERY INFO ######
# Calculate the start time based on ${PROBES_NUM}, ${PROBES_INTERVAL} (seconds) and ${END_TIME}=${PDATE}
# https://prometheus.io/docs/prometheus/latest/querying/api/#range-queries
# query_range: &start=2024-08-18T20:10:30.781Z&end=2024-08-20T20:11:00.781Z&step=15s
# query: &time=2024-08-18T20:10:30.781Z


if [[ "$(isEmpty ${PDATE})" == "true" ]]; then
    end_time_epoch=${current_time_epoch}
    END_TIME=${current_time_human}
else
    END_TIME=${PDATE}
    end_time_epoch=$(date -d "${END_TIME}" +%s)
fi

((start_time_epoch=end_time_epoch-((PROBES_NUM-1)*PROBES_INTERVAL))) # number of probes = ${PROBES_NUM}
START_TIME=$(date -u -d @${start_time_epoch} +'%Y-%0m-%0dT%H:%M:%S.%3NZ')

if [[ "${PROBES_ENABLED}" == "true" ]]; then
    display "Prometheus query range: ${PROBES_NUM} probes with ${PROBES_INTERVAL} seconds steps"
    display "Query range: start=${START_TIME}, end=${END_TIME}, step=${PROBES_INTERVAL}s"
fi

# the timestamp of the oldest metric:
oldest_date=$(getOldestMetricTimestamp)

if [[ "${oldest_date}" == "0" ]]; then

    info "INFO: oldest metric timestamp is not available"

elif [[ "${FORCED_PROTO}" == "false" && ("$(isEmpty ${oldest_date})" == "true" || "$(isFloatNumber "${oldest_date}")" != "true") ]]; then
    debug "FAILED TO GET OLDEST METRIC TIMESTAMP on ${PROM_PROTO}://${PROM_NAME}:${PROM_PORT}"
    if [[ "${PROM_PROTO}" == "${DEFAULT_PROTO}" ]]; then
        PROM_PROTO="${NON_DEFAULT_PROTO}"
        display "Auto-switching protocol to ${PROM_PROTO} - collecting from ${PROM_PROTO}://${PROM_NAME}:${PROM_PORT}"
    fi
else
    display "Oldest metric timestamp: ${oldest_date}"
fi

# Use a specified metrics json file, unless -w is specified for testing from an internal variable
if [[ "${USE_INTERNAL_TEST_METRICS}" != "true" ]]; then
    METRIC_QUERIES=$(cat ${METRICS_JSON_FILE}) # use a specified json file (or default file)
else 
    # FOR TESTING - use internal metrics from a variable: $metric_queries_test (see above) :
    METRIC_QUERIES=${metric_queries_test}
    display "===== TESTING : USING INTERNAL METRIC QUERIES ====="
fi


############### Process all querys in a loop ##############

# Initialize some counters
blank_query_count=0  # counting blank / empty results
failed_msg_count=0   # counting failed queries / messages
msg_count=0          # total useful messages
first_query="true"

# Number of metrics:
num_metrics=$(echo "${METRIC_QUERIES}" | jq length)
display "Starting query metrics: ${num_metrics} queries"

log "{
 \"SystemName\":\"${PROM_NAME}\", \"Port\":\"${PROM_PORT}\",
 \"StartTime\":\"${START_TIME}\",\"EndTime\":\"${END_TIME}\",
 \"Step\":\"${PROBES_INTERVAL}\",\"Probes\":\"${PROBES_NUM}\",
 \"Telemetry\":
 ["

while IFS= read -r line; do

    ### Increment the count of metrics/queries
    ((num_queries++))
    spinner

    debug "============================"

    eventId=$(echo "$line" | jq -c '.TelemetryID' | tr -d '"')
    description=$(echo "$line" | jq -c '.Description' | tr -d '"')
    metric_query=$(echo "$line" | jq -c '.Query' | tr -d '"')
    query_probe_step=$(echo "$line" | jq -c '.Step' | tr -d '"')
    query_num_probes=$(echo "$line" | jq -c '.Probes' | tr -d '"')

    # if query contains %PROBESTEP variable - replace it with a specified ${PROBES_INTERVAL} in seconds
    if [[ "$(echo "${metric_query}" | grep "%PROBESTEP")" != "" ]]; then
        metric_query=$(echo "${metric_query}" | sed "s/%PROBESTEP/${PROBES_INTERVAL}s/g")
    fi
    # if query contains %THRESHOLD variable - replace it with a specified ${THRESHOLD} in bytes
    if [[ "$(echo "${metric_query}" | grep "%THRESHOLD")" != "" ]]; then
        metric_query=$(echo "${metric_query}" | sed "s/%THRESHOLD/${THRESHOLD}/g")
    fi

    query_start_time=${START_TIME}
    if [[ "$(isEmpty "${query_probe_step}")" == "true" ]]; then
        query_probe_step=${PROBES_INTERVAL}
    fi
    if [[ "$(isEmpty "${query_num_probes}")" == "true" ]]; then
        query_num_probes=${PROBES_NUM}
    else
        ((query_start_time_epoch=end_time_epoch-((query_num_probes-1)*query_probe_step)))
        if [[ "${query_start_time_epoch}" -lt "${oldest_date_epoch}" ]]; then
            query_start_time_epoch=$oldest_date_epoch
        fi
        query_start_time=$(date -u -d @${query_start_time_epoch} +'%Y-%0m-%0dT%H:%M:%S.%3NZ')
    fi

    debug "[$num_queries] ${eventId} : '$description' : Query=$metric_query"
   
    if [[ "${PROBES_ENABLED}" == "true" ]]; then
        query_result=$(make_query_range "${metric_query}" "${query_start_time}" "${END_TIME}" "${query_probe_step}")
    else
        query_result=$(make_query "${metric_query}" "${PDATE}")
    fi
    debug "query_result=${query_result}"

    # if step is different from a global value, then add it to the output for the corresponding query
    step_string=""
    if [[ "${query_probe_step}" != "${PROBES_INTERVAL}" ]]; then
        step_string=",
 \"Step\":\"${query_probe_step}\""
    fi

    probe_string=""
    if [[ "${query_num_probes}" != "${PROBES_NUM}" ]]; then
        probe_string=",
 \"Probes\":\"${query_num_probes}\""
    fi

    comma=""
    if [[ "${num_metrics}" != "${num_queries}" ]]; then
        comma=","
    fi

    log "\
  {
   \"TelemetryID\":\"${eventId}\", \"Description\":\"${description}\",
   \"Query\":\"${metric_query}\",
   \"Prometheus\":${query_result}${step_string}${probe_string}
  }${comma}"

    ### Get the "status" field from the result
    status=$(echo "${query_result}" | jq -c .status | tr -d '"')

    if [[ "${status}" == "success" ]] ; then
        debug "SUCCESS: [$num_queries]: ${eventId}, '${description}'"

        spinner

        result=$(echo "${query_result}" | jq -c .data.result)
        if [[ "${result}" == "[]" || "${result}" == "" ]] ; then
            ### Blank reply - record it
            ((blank_query_count++))
            display "INFO: Blank result: ${eventId}, '${description}'"
        fi
    else
        ### Failed query - record it
        ((failed_msg_count++))
        display "ERROR: Failed request: ${eventId}, '${description}'"
    fi

done < <(echo "${METRIC_QUERIES}" | jq -rc '.[] ') 

log " ]
}"

#################
# Final printouts
#

if [[ "${PROBES_ENABLED}" == "true" ]]; then
  display "Collected ${num_queries} metrics, each with ${PROBES_NUM} probes and ${PROBES_INTERVAL} seconds step"
else
  display "Collected ${num_queries} metrics"
fi

if [[ "${blank_query_count}" != "0" ]]; then
    display "INFO: ${blank_query_count} blank queries"
fi

if [[ "${failed_msg_count}" != "0" ]]; then
    display "INTERNAL-ERROR: ${failed_msg_count} failed queries"
fi

display "Saved results in ${OUTPUT_FILE} file"

if [[ "${USE_INTERNAL_TEST_METRICS}" == "true" ]]; then
    # FOR TESTING WITH A JSON VARIABLE "$metric_queries_test (see above) :
    display "===== TESTING : USED INTERNAL METRIC QUERIES ====="
fi

# Calculate time to run
script_end_time=$(date -u +%s)
((script_run_seconds=script_end_time-current_time_epoch))
display "Total run time: ${script_run_seconds} sec"

