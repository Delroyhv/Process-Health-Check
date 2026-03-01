#!/bin/bash
#
#  We're assuming the extracted subdir's are CS instances. If not, well, no harm done
#

LOG_DIR=${1:-"."}

LOGNAME_SUFFIX='_dls_server.log'
ALL_DLS_DIR="all_dls/"
ALL_DLS_SORTED_FILE="all_dls_sorted.log"


# Switch to a specified log directory and remember directory where started
pushd "${LOG_DIR}" || exit 1

if [[ ! -d ${ALL_DLS_DIR} ]]; then
    mkdir ${ALL_DLS_DIR}
fi

created=0
skipped=0

for dir in */;
do
    cd "$dir" || exit 1

    dir_short=$(echo "${dir}" | tr -d "/")
    logname="${ALL_DLS_DIR}${dir_short}${LOGNAME_SUFFIX}"
    full_logname="../${logname}"

    if [[ "${dir}" == "${ALL_DLS_DIR}" ]]; then
        continue
    fi
    if [ -f "${full_logname}" ] ; then
        rm "${full_logname}"
    fi
    files=$(find . -path "*lifecycle*" -name "*server.log*" | sort -n)
    if [[ ${files} != "" ]]; then
        echo "$files" | xargs -d '\n' cat > ${full_logname}
        echo "Creating ${logname}"
        ((created++))
    else
        echo "Skipping ${dir_short}"
        ((skipped++))
    fi
    cd ..
done

if [[ "${created}" == "0" ]]; then
    echo "No DLS logs found"
else 
    # Generate a sorted DLS log file for DBO policy log records
    echo "Found DLS logs on ${created} nodes, skipped ${skipped} nodes"
    cat ${ALL_DLS_DIR}*${LOGNAME_SUFFIX} | sort -k1,1 -k2,2 > ${ALL_DLS_SORTED_FILE}
fi

# Change dir back to where we started
popd || exit 1

exit 0

