#!/bin/bash

alert_def_file=$1
log_prefix=${2:-"hcpcs_collection_def"}

if [[ ( "${alert_def_file}" == *"hcpcs"* ) && ( "${alert_def_file}" == *"alert"*) ]]; then
    log_file="${log_prefix}_autogen.json"
else    
    log_file="${log_prefix}_autogen_${alert_def_file}"
fi

if [[ "$1" == "-h" || "$1" == "" ]]; then
    echo "Generates collection definitions file based on alert & telemetry definitions file
    $0 <alert-def-file> [<collection-prefix-output>]
       <alert-def-file>          - alert & telemetry definitions file (required)
       <collection-prefix-output> - prefix for output collection definition file (default: ${log_prefix})"
    exit
fi

if [[ ! -f ${alert_def_file} ]]; then
    echo "ERROR: CANNOT FIND ${alert_def_file} file"
    exit
fi

if [[ -f ${log_file} ]]; then
    mv ${log_file} ${log_file}.bak
fi

##################
# Generate Telemetry definitions file by 
# * stripping some fields from alerts definitions json file and 
# * also by removing entries with duplicate TelemetryIDs.


alerts_def=$(cat ${alert_def_file})

num_alerts=$(echo "${alerts_def}" |  jq -r '.[].AlertID' | grep -v "null" | wc -l) 
num_entries=$(echo "${alerts_def}" | jq length)

# Add start of array symbol:
collect_def="["

# Copy some selected fields, ignoring all other fields from teh Alerts json file:
collect_def+=$(echo "${alerts_def}" | jq -r '.[] | 
"{\"TelemetryID\":\"\(.TelemetryID)\",\"Description\":\"\(.Description)\",\"Query\":\"\(.Query)\",\"Step\":\"\(.Step)\",\"Probes\":\"\(.Probes)\",\"Frequency\":\"\(.Frequency)\"},"')

# Remove empty (null) entries:
collect_def=$(echo "${collect_def//,\"Step\":\"null\"/}")
collect_def=$(echo "${collect_def//,\"Probes\":\"null\"/}")
collect_def=$(echo "${collect_def//,\"Frequency\":\"null\"/}")

# Remove the last comma ','
collect_def="${collect_def%?}"

# Add end of array symbol
collect_def+="]"

echo "${collect_def}" | jq . > "_${log_file}"

# Count the number of entries (it should match the number of Alerts)
num_alerts_def=$(echo "${collect_def}" | jq length)

# Remove duplicate entries - keep only one TelemetryID if multiple Alerts depend on it 
# "jq -s" brings it back to an array format:
collect_def=$(echo "${collect_def}" | jq -r '. | group_by(.TelemetryID)[] | .[0] ' | jq -s)

# Count the number of Telemetry entries:
num_collect_def=$(echo "${collect_def}" | jq length)

# Save Telemetry array of entries into a output file:
echo "${collect_def}" > ${log_file}

echo "Processed ${num_entries} alert & telemetry entries (including ${num_alerts} alerts), created ${num_collect_def} entries for Collection Definitions."
echo "Generated ${log_file} file from ${alert_def_file} input file."
