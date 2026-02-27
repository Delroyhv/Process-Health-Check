#!/usr/bin/env bash
#
# ========================================================================
# Copyright (c) by Hitachi, 2021-2024. All rights reserved.
# ========================================================================
#
# It analyzes information about DB partitions in the HCP for Cloud Scale system.
#

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${_script_dir}/gsc_core.sh"

_debug=0            # debug mode
_verbose="false"    # verbose

_default_output_file="health_report_partitionInfo.log"

_default_part_count_per_node_file_short="hcpcs_parse_partitions_leader_count.log"
_default_app_bucket_file_short="app_per_bucket.txt"
_default_threshold_file_short="partition_split_threshold.out"
_default_map_file_short="hcpcs_parse_partitions_map.log"
_default_state_file_short="hcpcs_parse_partitions_state.log"

_log_dir="."
_output_file=${_default_output_file}
_health_tools_dir="${_script_dir}"

_err=0 # count of issues

usage() {
    local _this_filename
    _this_filename=$(basename "$0")

    echo "\
This script validates/checks information about DB partition.

${_this_filename} -d <dir-name> -o <output-file>

${_this_filename} :

   -d <dir-name>           directory with input files

   -o <output_log_file>    output log file (default: ${_default_output_file}
"
}

##############################
#
# Check the input parameters:
#
getOptions() {
    local _opt
    while getopts "d:o:vh" _opt; do
        case ${_opt} in
            d)  _log_dir=${OPTARG}
                ;;

            v)  _verbose="true"
                _debug=1
                ;;

            o)  _output_file=${OPTARG}
                ;;

            *)  usage
                exit 0
                ;;
        esac
    done
}

##############################
# Aggregate partition split growth from *splitpartition.json files.
# Finds all non-error files under _log_dir, deduplicates by parentId,
# and reports splits per week, month, quarter, and year.
#
chk_partition_split_growth() {
    gsc_log_info "# checking partition split growth:"

    local -a _spj_files=()
    mapfile -t _spj_files < <(find "${_log_dir}" -name '*splitpartition.json' \
        ! -name '*.err' 2>/dev/null | sort)

    if [[ "${#_spj_files[@]}" -eq 0 ]]; then
        gsc_loga "INFO: No splitpartition.json files found — split growth data unavailable"
        return
    fi

    local _awkprog
    _awkprog=$(cat << 'AWKEOF'
BEGIN {
  split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", mn)
  for (i=1; i<=12; i++) mnum[mn[i]]=i
  split("0 31 59 90 120 151 181 212 243 273 304 334", cd)
}
{
  mon=$1; d=$2; gsub(/,/,"",d); d+=0
  yr=$3;  gsub(/,/,"",yr); yr+=0
  m=mnum[mon]
  leap=(yr%4==0 && (yr%100!=0||yr%400==0))
  doy=cd[m]+d; if(m>2&&leap) doy++
  weeknum=int((doy-1)/7)+1
  q=int((m-1)/3)+1
  per_week[sprintf("%04d-W%02d",yr,weeknum)]++
  per_month[sprintf("%04d-%02d",yr,m)]++
  per_qtr[sprintf("%04d-Q%d",yr,q)]++
  per_year[yr]++
  total++
}
END {
  print "Per year:"
  ny=0; for(y in per_year) yk[ny++]=y
  for(i=0;i<ny;i++) for(j=i+1;j<ny;j++) if(yk[i]>yk[j]){t=yk[i];yk[i]=yk[j];yk[j]=t}
  for(i=0;i<ny;i++) printf "  %s: %d\n",yk[i],per_year[yk[i]]
  print ""
  print "Per quarter:"
  nq=0; for(q in per_qtr) qk[nq++]=q
  for(i=0;i<nq;i++) for(j=i+1;j<nq;j++) if(qk[i]>qk[j]){t=qk[i];qk[i]=qk[j];qk[j]=t}
  for(i=0;i<nq;i++) printf "  %s: %d\n",qk[i],per_qtr[qk[i]]
  print ""
  print "Per month:"
  nm=0; for(m in per_month) mk[nm++]=m
  for(i=0;i<nm;i++) for(j=i+1;j<nm;j++) if(mk[i]>mk[j]){t=mk[i];mk[i]=mk[j];mk[j]=t}
  for(i=0;i<nm;i++) printf "  %s: %d\n",mk[i],per_month[mk[i]]
  print ""
  print "Top 10 busiest weeks:"
  nw=0; for(w in per_week) wkarr[nw++]=w
  lim=(nw<10)?nw:10
  for(i=0;i<lim;i++){
    mx=i
    for(j=i+1;j<nw;j++) if(per_week[wkarr[j]]>per_week[wkarr[mx]]) mx=j
    tmp=wkarr[i]; wkarr[i]=wkarr[mx]; wkarr[mx]=tmp
    printf "  %s: %d\n",wkarr[i],per_week[wkarr[i]]
  }
  print ""
  printf "Total split events (net new partitions): %d\n", total
}
AWKEOF
)

    local _growth
    _growth=$(jq -rs 'unique_by(.parentId) | .[] | .date' \
        "${_spj_files[@]}" 2>/dev/null | awk "${_awkprog}")

    local _total
    _total=$(printf '%s\n' "${_growth}" | awk '/^Total/ {print $NF}')

    gsc_loga "INFO: Partition split growth — ${_total} total split events \
(${#_spj_files[@]} file(s), deduplicated by parentId):"
    local _in_qtr=0
    while IFS= read -r _gl; do
        gsc_loga "  ${_gl}"
        if [[ "${_gl}" == "Per quarter:" ]]; then
            _in_qtr=1
            gsc_log_info "Per quarter:"
        elif [[ -z "${_gl}" && "${_in_qtr}" -eq 1 ]]; then
            _in_qtr=0
        elif [[ "${_in_qtr}" -eq 1 ]]; then
            gsc_log_info "  ${_gl}"
        fi
    done <<< "${_growth}"
}


############################

getOptions "$@"

gsc_log_info "== ANALYZING PARTITION INFO =="

# Check if LOG DIR exists
if [[ "${_log_dir}" != "" && ! -d ${_log_dir} ]]; then
    gsc_log_error "ERROR: CANNOT FIND ${_log_dir} directory."
    exit
fi

# Check if an input MAP file specified
_input_file_map=$(find ${_log_dir} | grep -m 1 ${_default_map_file_short} | head -n 1)
if [[ "${_input_file_map}" == "" ]]; then
    gsc_log_warn "WARNING: CANNOT FIND ${_default_map_file_short} map file in ${_log_dir} directory."
    gsc_log_info "Running prep_partInfo script..."
    ${_health_tools_dir}/parse_partInfo_keyspaces.sh -d ${_log_dir} -o "prep_${_output_file}"
fi

gsc_log_debug "==== Find ${_default_state_file_short} state file in ${_log_dir} directory."
_input_file_state=$(find ${_log_dir} | grep -m 1 ${_default_state_file_short} | head -n 1)
if [[ "${_input_file_state}" == "" ]]; then
    gsc_log_error "ERROR: CANNOT FIND ${_default_state_file_short} state file in ${_log_dir} directory."
    exit
fi

gsc_log_debug "==== Find ${_default_part_count_per_node_file_short} count per node file in ${_log_dir} directory."
_part_count_per_node_file=$(find ${_log_dir} | grep -m 1 ${_default_part_count_per_node_file_short} | head -n 1)
if [[ "${_part_count_per_node_file}" == "" ]]; then
    gsc_log_error "ERROR: CANNOT FIND ${_part_count_per_node_file} file in ${_log_dir} directory."
    exit
fi

_threshold_file=$(find ${_log_dir} | grep -m 1 ${_default_threshold_file_short} | head -n 1)
if [[ "${_threshold_file}" == "" ]]; then
    gsc_log_warn "WARNING: CANNOT FIND ${_default_threshold_file_short} threshold file in ${_log_dir} directory."
fi

# Check if output file exists and if so, rename it
if [[ -f ${_output_file} ]]; then
    mv ${_output_file} ${_output_file}.bak
fi

if [[ "${_input_file_map}" != "" ]]; then
    gsc_log_debug "==== Search for Leader in ${_input_file_map} map file"
    _map_file_lines=$(cat ${_input_file_map} | grep "Leader" | wc -l)
    if (( ${_map_file_lines} == 0 )) ; then
        gsc_log_warn "WARNING: INCOMPLETE DATA IN INPUT MAP FILE: ${_input_file_map}"
    fi
fi

gsc_log_debug "==== Search for 15 in ${_input_file_state} state file"
_state_file_lines=$(cat ${_input_file_state} | grep " 15 " | wc -l)
if (( ${_state_file_lines} == 0 )) ; then
    gsc_log_warn "WARNING: INCOMPLETE DATA IN INPUT STATE FILE: ${_input_file_state}"
fi

#######################################################

gsc_log_debug "Start"

gsc_log_info "# checking partitions per node count:"
if [[ ! -f ${_part_count_per_node_file} ]]; then
   gsc_log_error "ERROR: failed to process partition map file"
else

   _num_lines=$(cat ${_part_count_per_node_file} | grep -n "Leader"  | awk -F':' ' { print $1 } ')
   ((_num_lines--))
   _part_per_node=$(head -n +${_num_lines} ${_part_count_per_node_file} | grep -v -i "partition" )

   _num_mdgw=$(echo "${_part_per_node}" | wc -l)

   gsc_log_info "DB partitions per MDGW node (${_num_mdgw} nodes):"
   gsc_loga "${_part_per_node}"

   _warn_1000=$(echo "${_part_per_node}" | awk ' $1 > 1000 ' | wc -l)
   _warn_1500=$(echo "${_part_per_node}" | awk ' $1 > 1500 ' | wc -l)
   _warn_2000=$(echo "${_part_per_node}" | awk ' $1 > 2000 ' | wc -l)

   if [[ "${_warn_2000}" -gt "0" ]] ; then

        ((_err++))
        gsc_loga "CRITICAL: EXTREMELY HIGH number of partitions per node (>2,000):"
        while IFS= read -r _pline; do
            [[ -z "${_pline// }" ]] && continue
            _cnt=$(echo "${_pline}" | awk '{print $1}')
            _nd=$(echo "${_pline}" | awk '{print $2}')
            (( _cnt > 2000 )) && gsc_loga "  node ${_nd}: ${_cnt} partitions"
        done <<< "${_part_per_node}"

   elif [[ "${_warn_1500}" -gt "0" ]] ; then

        ((_err++))
        gsc_loga "DANGEROUS: VERY HIGH number of partitions per node (>1,500):"
        while IFS= read -r _pline; do
            [[ -z "${_pline// }" ]] && continue
            _cnt=$(echo "${_pline}" | awk '{print $1}')
            _nd=$(echo "${_pline}" | awk '{print $2}')
            (( _cnt > 1500 )) && gsc_loga "  node ${_nd}: ${_cnt} partitions"
        done <<< "${_part_per_node}"

   elif [[ "${_warn_1000}" -gt "0" ]] ; then

        ((_err++))
        gsc_loga "WARNING: HIGH number of partitions per node (>1,000):"
        while IFS= read -r _pline; do
            [[ -z "${_pline// }" ]] && continue
            _cnt=$(echo "${_pline}" | awk '{print $1}')
            _nd=$(echo "${_pline}" | awk '{print $2}')
            (( _cnt > 1000 )) && gsc_loga "  node ${_nd}: ${_cnt} partitions"
        done <<< "${_part_per_node}"

   else
        gsc_loga "INFO: Partition count per node is normal (all nodes < 1,000 partitions)"
   fi
fi

gsc_log_info "# checking partition split thresholds:"
_split_files=()
mapfile -t _split_files < <(find "${_log_dir}" -name '*split*.out' 2>/dev/null | sort)
if [[ "${#_split_files[@]}" -eq 0 ]]; then
   gsc_loga "WARNING: No partition split threshold files found in ${_log_dir}"
else
   _split_summary=$(cat "${_split_files[@]}" | awk '
      /^Metadata-/ { svc=$0; gsub(/:$/,"",svc) }
      /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:/ {
         ip=$1; gsub(/:$/,"",ip)
         thresh=$NF
         key=svc SUBSEP ip
         if (key in seen) next
         seen[key]=1
         print svc, ip, thresh
      }
   ' | sort -k1,1 -k3,3V)

   _max_thresh=$(echo "${_split_summary}" | awk '
      BEGIN { max_num=0; max_thresh="" }
      {
         thresh=$NF; num=thresh; gsub(/[^0-9]/,"",num)
         if (num+0 > max_num) { max_num=num+0; max_thresh=thresh }
      }
      END { print max_thresh }
   ')

   gsc_loga "INFO: Partition split thresholds (largest: ${_max_thresh}):"
   while IFS= read -r _sline; do
      [[ -z "${_sline// }" ]] && continue
      gsc_loga "  ${_sline}"
   done <<< "${_split_summary}"
fi

gsc_log_info "# checking partitions health state:"

if [[ ! -f ${_input_file_state} ]]; then
   gsc_log_error "ERROR: failed to process partition state file"
else
   _total_partitions=$(cat ${_input_file_state} | wc -l)

   if [[ ${_total_partitions} -ge 15 ]]; then
       _leaderless=$(cat ${_input_file_state} | grep false | wc -l)
       _over_protected=$(cat ${_input_file_state} | grep -v false | awk ' NF > 8 ' | wc -l)
       _fully_protected=$(cat ${_input_file_state} | grep -v false | awk ' NF == 8 ' | wc -l)
       _under_protected=$(cat ${_input_file_state} | grep -v false | awk ' NF < 8 ' | wc -l)

       gsc_log_info "Partitions: Total=${_total_partitions}, Fully protected=${_fully_protected}"

       if (( ${_leaderless} > 0 || ${_over_protected} > 0 || ${_under_protected} > 0 )); then
           ((_err++))
           gsc_loga "WARNING: Leaderless=${_leaderless}, Over-protected=${_over_protected}, Under-protected=${_under_protected}"
       fi
   else
       gsc_log_info "INFO: Skiping partition health state analysis — state log has only ${_total_partitions} lines (threshold: 15)"
   fi
fi

chk_partition_split_growth

if [[ "${_err}" -gt 0 ]]; then
    gsc_loga "Detected ${_err} issues"
else
    gsc_loga "INFO: No issues found"
fi

gsc_log_info "Processed partition info. Generated ${_output_file} file."
