#!/usr/bin/env bash
#
# generate_partition_report.sh
#

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_data_script="${_script_dir}/get_partition_details.sh"

if [[ ! -f "${_data_script}" ]]; then
    echo "Error: get_partition_details.sh not found."
    exit 1
fi

_data=$("${_data_script}")

echo "========================================================="
echo "       PARTITION WARNING AND BALANCE REPORT"
echo "========================================================="

# 1. Balance Report
echo -e "
--- CLUSTER BALANCE REPORT ---"
_leaders=$(echo "${_data}" | awk '/number_of_leader IP/,/^$/ { if ($1 ~ /^[0-9]+$/) print $0 }')

_err=0
while IFS= read -r _line; do
    [[ -z "${_line}" ]] && continue
    _cnt=$(echo "${_line}" | awk '{print $1}')
    _ip=$(echo "${_line}" | awk '{print $2}')
    
    _status="OK"
    if (( _cnt > 2000 )); then
        _status="CRITICAL (>2000)"
        ((_err++))
    elif (( _cnt > 1500 )); then
        _status="DANGEROUS (>1500)"
        ((_err++))
    elif (( _cnt > 1000 )); then
        _status="WARNING (>1000)"
        ((_err++))
    fi
    
    printf "  %-15s : %4d partitions [%s]
" "${_ip}" "${_cnt}" "${_status}"
done <<< "${_leaders}"

# 2. Safety Warnings
echo -e "
--- PARTITION SAFETY WARNINGS ---"
_bad_info=$(echo "${_data}" | sed -n '/###### partitionState bad partitions analysis #######/,$p' | grep -v "######")

_safety_issues=0
while IFS= read -r _line; do
    [[ -z "${_line}" ]] && continue
    if [[ "${_line}" == *"No partitions found"* ]]; then
        continue
    else
        echo "  [ALERT] ${_line}"
        ((_safety_issues++))
    fi
done <<< "${_bad_info}"

if (( _safety_issues == 0 )); then
    echo "  No data protection or leadership issues detected."
fi

# 3. Summary
echo -e "
--- SUMMARY ---"
if (( _err > 0 || _safety_issues > 0 )); then
    echo "  STATUS: ACTION REQUIRED"
    echo "  - ${_err} balance issue(s) detected."
    echo "  - ${_safety_issues} safety issue(s) detected."
else
    echo "  STATUS: HEALTHY"
    echo "  - All partition metrics within normal parameters."
fi
echo "========================================================="
