#!/usr/bin/env bash
#
# ========================================================================
# Copyright (c) by Hitachi Vantara, 2024. All rights reserved.
# ========================================================================
#
# Check Data Lifecycle Service (DLS) task health from support bundle output.
#
# Reads two files collected by collect_healthcheck_data:
#   dls-tasks-check_all.out  — hole detection (✅ pass / ❌ fail per task type)
#   dls-tasks-count_all_all.out — task counts by type and state
#
# Severity:
#   ERROR   — ❌ line in tasks-check: holes found in a task range (data integrity risk)
#   WARNING — FAILED or CANCELED tasks present in tasks-count
#   OK      — all task types passed hole detection, no bad states
#

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${_script_dir}/gsc_core.sh"

_default_output_file="health_report_dls.log"
_log_dir="."
_output_file="${_default_output_file}"

usage() {
    local _this
    _this=$(basename "$0")
    echo "\
Check DLS task health from support bundle collected output.

${_this} [-d <dir>] [-o <output>]

  -d <dir>     directory with support bundle (default: .)
  -o <output>  output log file (default: ${_default_output_file})
"
}

getOptions() {
    while getopts "d:o:h" _opt; do
        case "${_opt}" in
            d) _log_dir="${OPTARG}" ;;
            o) _output_file="${OPTARG}" ;;
            *) usage; exit 0 ;;
        esac
    done
}

############################

getOptions "$@"

gsc_log_info "== CHECKING DLS TASK HEALTH =="

gsc_rotate_log "${_output_file}"

# Discover check and count files
mapfile -t _check_files < <(find "${_log_dir}" -name "dls-tasks-check_all.out" 2>/dev/null | sort)
mapfile -t _count_files < <(find "${_log_dir}" -name "dls-tasks-count_all_all.out" 2>/dev/null | sort)

if [[ "${#_check_files[@]}" -eq 0 && "${#_count_files[@]}" -eq 0 ]]; then
    gsc_loga "[ OK     ] DLS: No DLS task files found — data not collected in this bundle"
    exit 0
fi

gsc_log_info "Found ${#_check_files[@]} dls-tasks-check file(s), ${#_count_files[@]} dls-tasks-count file(s)"

_total_errors=0
_total_warnings=0

# ── Hole detection (dls-tasks-check_all.out) ─────────────────────────────────

for _f in "${_check_files[@]}"; do
    _host=$(echo "${_f}" | grep -o 'cluster_triage/[^/]*' | head -n1 | cut -d/ -f2)
    [[ -z "${_host}" ]] && _host="unknown"

    _fail_types=()
    _pass_count=0
    _current_type=""

    while IFS= read -r _line; do
        _msg="${_line#* - INFO - }"
        if [[ "${_msg}" == Checking\ for\ holes\ in\ * ]]; then
            _current_type="${_msg#Checking for holes in }"
            _current_type="${_current_type% tasks}"
        elif [[ "${_msg}" == *"✅"* ]]; then
            (( _pass_count++ )) || true
        elif [[ "${_msg}" == *"❌"* ]]; then
            _fail_types+=("${_current_type}")
        fi
    done < "${_f}"

    if [[ "${#_fail_types[@]}" -gt 0 ]]; then
        for _t in "${_fail_types[@]}"; do
            gsc_loga "ERROR: DLS hole detected on ${_host}: ${_t} tasks have gaps — contact ASPSUS"
            gsc_log_error "DLS hole detected on ${_host}: ${_t}"
        done
        (( _total_errors += ${#_fail_types[@]} )) || true
    else
        gsc_loga "[ OK     ] DLS: ${_host}: ${_pass_count} task type(s) passed hole detection"
        gsc_log_ok "DLS hole check clean on ${_host} (${_pass_count} types)"
    fi
done

# ── Task state summary and bad-state detection (dls-tasks-count_all_all.out) ──

for _f in "${_count_files[@]}"; do
    _host=$(echo "${_f}" | grep -o 'cluster_triage/[^/]*' | head -n1 | cut -d/ -f2)
    [[ -z "${_host}" ]] && _host="unknown"

    _total_tasks=""
    _current_type=""
    _bad_states=()

    while IFS= read -r _line; do
        if [[ "${_line}" == Total\ DLS\ tasks:* ]]; then
            _total_tasks="${_line#Total DLS tasks: }"
        elif [[ "${_line}" =~ ^([A-Z_]+):[0-9]+$ ]]; then
            _current_type="${BASH_REMATCH[1]}"
        elif [[ "${_line}" =~ ^[[:space:]]+(FAILED|CANCELED):[[:space:]]*([0-9]+)$ ]]; then
            _bad_states+=("${_current_type} ${BASH_REMATCH[1]}=${BASH_REMATCH[2]}")
        fi
    done < "${_f}"

    for _s in "${_bad_states[@]}"; do
        gsc_loga "WARNING: DLS bad task state on ${_host}: ${_s} — investigate DLS health"
        gsc_log_warn "DLS bad task state on ${_host}: ${_s}"
        (( _total_warnings++ )) || true
    done

    if [[ -n "${_total_tasks}" ]]; then
        gsc_loga "[ INFO   ] DLS: ${_host}: ${_total_tasks} total tasks"
        gsc_log_info "DLS task count on ${_host}: ${_total_tasks} total"
    fi
done

# ── Final summary line ────────────────────────────────────────────────────────

gsc_loga "++++++++++++++++++++++++++++++++++++++++++++"
if [[ "${_total_errors}" -gt 0 ]]; then
    gsc_loga "ERROR: DLS task holes found (${_total_errors} type(s)) — data integrity risk, contact ASPSUS"
    gsc_log_error "DLS: ${_total_errors} hole detection failure(s)"
elif [[ "${_total_warnings}" -gt 0 ]]; then
    gsc_loga "WARNING: DLS bad task states found (${_total_warnings}) — investigate DLS health"
    gsc_log_warn "DLS: ${_total_warnings} bad task state(s)"
else
    gsc_loga "[ OK     ] DLS: All task types passed hole detection across ${#_check_files[@]} cluster(s)"
    gsc_log_ok "DLS: all clean"
fi
gsc_loga "++++++++++++++++++++++++++++++++++++++++++++"
