#!/bin/bash

dls_log=$1

if [[ "$1" == "" || "$1" == "-h" ]]; then
    echo "Analyze DLS log file for an issue with submiited tasks
    $0 <dls-log-file>"
    exit
fi

if [[ ! -f ${dls_log} ]]; then
    echo "ERROR: cannot find file ${dls_log}"
    exit
fi

dls_log_name="${dls_log%.*}"

log_file="${dls_log_name}_parsed.txt"

if [[ -f ${log_file} ]]; then
    mv ${log_file} ${log_file}.bak
fi


function progress() {
  echo "$1"
}

function log () {
  echo "$1" >> ${log_file}
}

function loga () {
  echo "$1" | tee -a ${log_file}
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


dbo_tasks=$(cat ${dls_log} | grep "\[rabbitManagedConn" | grep "DeleteBackendRunner")

tasks=0
declare -A states=()
declare -A ranges=()


while read -r log_entry ;  do
    task=$(echo "${log_entry}" | awk '{ print $6 }')

    job_string1=$(echo "${log_entry}" | awk -F"uuid=" '{ print $2 }')
    storageId=$(echo "${job_string1}" | awk -F"[{},]" '{ print $1 }')
    path=$(echo "${job_string1}" | awk -F"path=" '{ print $2}' | awk -F"[{},]" '{ print $1 }')

    if [[ "$(echo "${log_entry}" | grep -c "version=" )" == "0" ]]; then
        job_string2=$(echo "${log_entry}" | awk -F"Processing range" '{print $2}')
    else
        job_string2=$(echo "${log_entry}" | awk -F"version=" '{print $2}')
    fi

    version=$(echo "${job_string2}" | awk -F"[{},]" '{ print $1 }')
    state=$(echo "${job_string2}" | awk -F"state=" '{ print $2 }' | awk -F"," ' { print $1}')
    
    if [[ "${state}" == "RUNNING" ]]; then 
        state="${task}"
    fi

    job_string3=$(echo "${job_string2}" | awk -F"keySpaceId=" '{ print $2}')
    keyspace=$(echo "${job_string3}" | awk -F"[{},]" '{ print $1 }')

    if [[ "${task}" == "Processing" ]]; then
        job_string4=$(echo "${job_string2}" | awk -F" - " '{ print $2}')
    else
        job_string4=$(echo "${job_string2}" | awk -F"endKey=" '{ print $2}')
    fi

    end_storageId=$(echo "${job_string4}" | awk -F"StoredObject.ID{storageComponentId=StorageComponent.ID{uuid=" '{ print $2 }' | awk -F"[{},]" '{ print $1 }')
    if [[ "${end_storageId}" == "" || "${end_storageId}" == "null" ]]; then
        end_storageId="null"
        end_path="null"
    else
        end_path=$(echo "${job_string4}" | awk -F"path=" '{ print $2 }' | awk -F"[{},]" '{ print $1 }')
    fi

    if [[ "${task}" == "Processing" && "${state}" == "" ]]; then
        state="Processing"
        version="-"
    fi

    if [[ "${state}" == "" ]]; then

        progress "========= NO STATE: task=${task} version=${version}"

    elif [[ "${state}" != "" ]]; then
        ((states["${state}"]++))
    else
        progress "========= MISSING STATE: ${log_entry} "
    fi

    range="${storageId}:${path} :: ${end_storageId}:${end_path}"
    obj_states="${ranges[${range}]}"
    if [[ "${obj_states}" == "" ]]; then
        ranges[${range}]="1:${state}"
    else
        bcount=$(echo "${obj_states}" | awk -F":" '{print $1}')
        bstates=$(echo "${obj_states}" | awk -F":" '{print $2}')
        ((bcount++))
        ranges[${range}]="${bcount}:${bstates} ${state}"
    fi

    ((tasks++))

    log "${tasks} : Task: ${task}, ${version}, ${state}, ${keyspace}, ${range}"

    spinner


done < <(echo "${dbo_tasks}")

progress "Number of Delete Backend Objects tasks: ${tasks}"

log "==============================================="
total_ranges=0
warnings=0
for range in "${!ranges[@]}"; do

    obj_states="${ranges["${range}"]}"
    if [[ "${obj_states}" == "" ]]; then
        log "INTERNAL_ERROR: ${range} - no states"
        continue
    fi
    bcount=$(echo "${obj_states}" | awk -F":" '{print $1}')
    bstates=$(echo "${obj_states}" | awk -F":" '{print $2}')

    lastState=$(echo "${bstates}" | awk 'END {print $NF}')

    if [[ "${lastState}" != "markCompleted" ]]; then
        log "WARNING: ${lastState} - ${range} [${bcount}] = ${bstates}"
        ((warnings++))
    fi
    ((total_ranges++))
done

log "==============================================="

for state in "${!states[@]}"; do
    loga "${state} = ${states[${state}]}"
done

loga "Total Delete Backend Objects ranges : ${total_ranges}, warnings: ${warnings}"
