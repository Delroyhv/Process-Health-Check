#!/bin/bash
LOG_DIR=${1:-"."}

TOOL_DIR=$(dirname $0)
ALL_DLS_SORTED_FILE="all_dls_sorted.log"
ALL_DLS_DBO="all_dls_dbr.log"
DLS_LOG_FILES="*_dls_server.log"
DLS_POLICY="DeleteBackendRunner"

if [[ "$1" == "-h" ]]; then
   echo "This script collects all DLS logs, sorts and parses them 
for issues in DLS Backend Delete Objects policy
   $0 <dls-log-dir>
   where
      <dls-log-dir> Optional, directory with HCP-CS log files (default is a current directory)
"
   exit
fi

${TOOL_DIR}/dls_get_all_logs.sh ${LOG_DIR}

if [[ ! -f ${LOG_DIR}/${ALL_DLS_SORTED_FILE} ]]; then
    echo "FILE ${LOG_DIR}/${ALL_DLS_SORTED_FILE} NOT FOUND"
    exit
fi


# Generate a sorted DLS log file for DBO policy log records
cat ${LOG_DIR}/${ALL_DLS_SORTED_FILE} | grep "${DLS_POLICY}" > ${LOG_DIR}/${ALL_DLS_DBO}

# Parse DLS log file 
${TOOL_DIR}/dls_parse.sh ${ALL_DLS_DBO}
