#!/bin/bash

alert_def_file=$1
log_prefix=${2:-"hcpcs_telemetry_def"}

if [[ ( "${alert_def_file}" == *"hcpcs"* ) && ( "${alert_def_file}" == *"alert"*) ]]; then
    log_file="${log_prefix}_autogen.json"
else    
    log_file="${log_prefix}_autogen_${alert_def_file}"
fi

if [[ "$1" == "-h" || "$1" == "" ]]; then
    echo "Generates telemetry definitions file based on alert definitions file
    $0 <alert-def-file> [<telemetry-prefix-output>]
       <alert-def-file>          - alert definitions file (required)
       <telemetry-prefix-output> - prefix for output telemetry definition file (default: ${log_prefix})"
    exit
fi

if [[ ! -f ${alert_def_file} ]]; then
    echo "ERROR: CANNOT FIND ${alert_def_file} file"
    exit
fi

if [[ -f ${log_file} ]]; then
    mv ${log_file} ${log_file}.bak
fi

# Add start of array symbol
telemetry_def="["

telemetry_def+=$(cat ${alert_def_file} | jq -r '.[] | 
"{\"TelemetryID\":\"\(.TelemetryID)\",\"Description\":\"\(.Description)\",\"Query\":\"\(.Query)\",\"Step\":\"\(.Step)\",\"Probes\":\"\(.Probes)\",\"Frequency\":\"\(.Frequency)\"},"')

# Remove empty (null) entries:
telemetry_def=$(echo "${telemetry_def//,\"Step\":\"null\"/}")
telemetry_def=$(echo "${telemetry_def//,\"Probes\":\"null\"/}")
telemetry_def=$(echo "${telemetry_def//,\"Frequency\":\"null\"/}")

# Remove the last comma ','
telemetry_def="${telemetry_def%?}"

# Add end of array symbol
telemetry_def+="]"

echo "${telemetry_def}" | jq . > "_${log_file}"

# Remove duplicate entries - keep only one TelemetryID if multiple Alerts depend on it
telemetry_def=$(echo "${telemetry_def}" | jq -r '. | group_by(.TelemetryID)[] | .[0] ')

echo "${telemetry_def}" | jq -s . > ${log_file}

# echo "${telemetry_def}" | jq . > ${log_file}

echo "Generated ${log_file} file from ${alert_def_file} input file."
