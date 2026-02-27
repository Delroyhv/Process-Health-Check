#!/bin/bash

dls_log=$1

if [[ "$1" == "" || "$1" == "-h" ]]; then
    echo "Analyze DLS log file for an issue with submiited tasks
    $0 <dls-log-file>"
    exit
fi

if [[ ! -f ${dls_log} ]]; then
    echo "ERROR: cannot find file {dls_log}"
    exit
fi


dbo_jobs=$(grep "DeleteBackendRunner markRunning DataLifecycleSplittableTask{typedId=TypedDataLifecycleTaskId{type=DELETE_BACKEND_OBJECTS, " "${dls_log}")

jobs=0
declare -A states=()

while read -r job
do
    start_storageId=$(echo "${job}" | awk -F"[{},]" '{ print $8 }')
    start_path=$(echo "${job}" | awk -F"," '{ print $10 }')
    version=$(echo "${job}" | awk -F"," '{ print $13 }')
    state=$(echo "${job}" | awk -F"," '{ print $14 }')
    end_storageId=$(echo "${job}" | awk -F"[{},]" '{ print $17 }')
    end_path=$(echo "${job}" | awk -F"[{},]" '{ print $19 }')
    keyspace=$(echo "${job}" | awk -F"[{},]" '{ print $25 }')
    echo " version: ${version}, state: ${state}, keyspace: ${keyspace}, start: {${start_storageId}, ${start_path}}, end: {${end_storageId}, ${end_path}}"

    ((jobs++))
    ((states["${state}"]++))
done <<< "${dbo_jobs}"

echo "Number of DBE jobs"

for state in "${!states[@]}"; do
    echo "${state} = ${states[${state}]}"
done
