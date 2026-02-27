#!/bin/bash
#
# ========================================================================
# Copyright (c) by Hitachi, 2021. All rights reserved.
# ========================================================================
#
# THIS SCRIPT MUST ONLY BE USED BY HITACHI VANTARA PERSONNEL.
#
# It collects information about the services running on the HCP for Cloud Scale system.
#

########################## START ###################

# Get Auth token

INPUT_JSON_FILE=$1
OUTPUT_FILE=${2:-"hcpcs_get_service_config.log"}

DEBUG=0

if [[ ! -f ${INPUT_JSON_FILE} ]]; then
    echo "ERROR: FILE NOT FOUND: $INPUT_JSON_FILE"
    exit
fi

if [[ -f ${OUTPUT_FILE} ]]; then
    mv ${OUTPUT_FILE} ${OUTPUT_FILE}.bak
fi


function loga() {
    echo "$1" | tee -a ${OUTPUT_FILE}
}

function debug() {
    if [[ "$DEBUG" != "0" ]]; then
        echo "$1"
    fi
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

####################################

line1=$(head -n 1 ${INPUT_JSON_FILE} | grep "#")

if [[ "${line1}" != "" ]]; then
    SERVICES_JSON=$(tail -n +2 ${INPUT_JSON_FILE})
else
    SERVICES_JSON=$(cat ${INPUT_JSON_FILE})
fi

# '.serviceConfigs[] | "\(.name) \(.config.propertyGroups[].configProperties[] | select(.name=="MAX_HEAP_SIZE").value) "')

serviceConfigs=$(echo "${SERVICES_JSON}" | jq -rc '.serviceConfigs[]')
if [[ "$(isEmpty ${serviceConfigs})" == "true" ]]; then
    echo "ERROR: wrong file format: ${INPUT_JSON_FILE}"
    exit
fi

if [[ "$(echo "${SERVICES_JSON}" | grep MAX_HEAP_SIZE)" == "" ]]; then
    echo "ERROR: wrong file format: ${INPUT_JSON_FILE} - missing MAX_HEAP_SIZE"
    exit
fi


echo "STARTING PROCESSING"

readarray -t serviceConfigs_array <<<"$serviceConfigs"
count=0

for serviceConfig in "${serviceConfigs_array[@]}" ; do

    if [[ "$(isEmpty ${serviceConfig})" == "true" ]]; then
        echo "skipping service config..."
        continue
    fi

    # Service name
    service_name=$(echo "${serviceConfig}" | jq -rc '.name')
    debug "${service_name}"

    # Service's max heap size
    heap_value=$(echo "${serviceConfig}" | jq -rc ' .config.propertyGroups[].configProperties[] | select(.name=="MAX_HEAP_SIZE").value' 2>/dev/null)

    # Service's Memory
    mem_value=$(echo "${serviceConfig}" | jq -rc '.config.propertyGroups[].configProperties[] | select(.name=="mem").value' 2>/dev/null)

    if [[ "$(isEmpty ${service_name})" != "true" && "$(isEmpty ${mem_value})" != "true" ]]; then
        loga "${service_name} ${mem_value} ${heap_value}"
	((count++))
    fi
done

if [[ "$count" != "0" ]]; then
    echo "Log file ${OUTPUT_FILE} was generated"
else
    echo "ERROR: failed to generate memory configs"
    echo "${serviceConfigs}"
fi
