#!/bin/bash
_date1=$(date)
_current_time_epoch=$(date -u +%s)

# Load unified GSC library for logging/helpers
_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -r "${_script_dir}/gsc_core.sh" ]]; then
    # shellcheck disable=SC1091
    . "${_script_dir}/gsc_core.sh"
else
    gsc_log_info()   { printf '[INFO ] %s\n' "$*" >&2; }
    gsc_log_warn()   { printf '[WARN ] %s\n' "$*" >&2; }
    gsc_log_error()  { printf '[ERROR] %s\n' "$*" >&2; }
    gsc_log_success(){ printf '[ OK  ] %s\n' "$*" >&2; }
fi

# ── Defaults ────────────────────────────────────────────────────────────────
_config_file="healthcheck.conf"
_full_detail=0
_no_metrics=0
_report_file=""

# ── Usage ────────────────────────────────────────────────────────────────────
usage() {
    echo "Usage: runchk.sh [-f healthcheck.conf] [--full-detail] [--no-metrics] [--report report.md] [-h]"
}

# ── Option parsing ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        -f)
            if [[ -n "${2-}" ]]; then
                _config_file="$2"; shift 2
            else
                gsc_log_error "-f requires a filename"; exit 1
            fi
            ;;
        --full-detail) _full_detail=1; shift ;;
        --no-metrics) _no_metrics=1; shift ;;
        --report)
            if [[ -n "${2-}" ]]; then
                _report_file="$2"; shift 2
            else
                gsc_log_error "--report requires a filename"; exit 1
            fi
            ;;
        -h|--help) usage; exit 0 ;;
        -*) gsc_log_error "Unknown option: $1"; usage; exit 1 ;;
        *) _config_file="$1"; shift ;;
    esac
done

# Source config file if it exists to get Prometheus details
if [[ -f "${_config_file}" ]]; then
    gsc_log_info "Sourcing configuration from ${_config_file}"
    # shellcheck disable=SC1090
    . "${_config_file}"
fi

# ── Setup Output Capture ─────────────────────────────────────────────────────
_tmp_report_output=$(mktemp)
gsc_add_tmp_dir "$(dirname "${_tmp_report_output}")"

# ── Run ──────────────────────────────────────────────────────────────────────
gsc_log_info "========= RUN ALL CHECKS ========="
gsc_log_info "Config: ${_config_file} | full-detail: ${_full_detail} | no-metrics: ${_no_metrics} | report: ${_report_file:-None}"

gsc_log_info "# RUN selfcheck.sh"
"${_script_dir}/selfcheck.sh" 2>&1 | tee -a "${_tmp_report_output}" || true

gsc_log_info "# RUN print_cluster_identity_summary.sh"
"${_script_dir}/print_cluster_identity_summary.sh" 2>&1 | tee -a "${_tmp_report_output}" || true

gsc_log_info "# RUN print_node_memory_summary.sh"
"${_script_dir}/print_node_memory_summary.sh" 2>&1 | tee -a "${_tmp_report_output}" || true

gsc_log_info "# RUN print_node_os_summary.sh"
"${_script_dir}/print_node_os_summary.sh" 2>&1 | tee -a "${_tmp_report_output}" || true

gsc_log_info "# RUN chk_cluster.sh"
"${_script_dir}/chk_cluster.sh" 2>&1 | tee -a "${_tmp_report_output}" || true

gsc_log_info "# RUN chk_lshw.sh"
"${_script_dir}/chk_lshw.sh" -d . 2>&1 | tee -a "${_tmp_report_output}" || true

gsc_log_info "# RUN prep_services_instances.sh"
"${_script_dir}/prep_services_instances.sh" . > health_report_services_instances.log 2>&1 || true
cat health_report_services_instances.log >> "${_tmp_report_output}"

gsc_log_info "# RUN chk_service_placement.sh"
"${_script_dir}/chk_service_placement.sh" 2>&1 | tee -a "${_tmp_report_output}" || true

gsc_log_info "# RUN chk_chrony.sh"
"${_script_dir}/chk_chrony.sh" -d . 2>&1 | tee -a "${_tmp_report_output}" || true

gsc_log_info "# RUN chk_top.sh"
"${_script_dir}/chk_top.sh" -d . 2>&1 | tee -a "${_tmp_report_output}" || true

gsc_log_info "# RUN prep_partitions_json.sh"
"${_script_dir}/prep_partitions_json.sh" 2>&1 | tee -a "${_tmp_report_output}" || true

gsc_log_info "# RUN get_partition_tool_info.sh"
"${_script_dir}/get_partition_tool_info.sh" 2>&1 | tee -a "${_tmp_report_output}" || true

gsc_log_info "# RUN chk_partInfo.sh"
"${_script_dir}/chk_partInfo.sh" -d . 2>&1 | tee -a "${_tmp_report_output}" || true

gsc_log_info "# RUN get_partition_details.sh"
"${_script_dir}/get_partition_details.sh" . 2>&1 | tee health_report_partition_details.log | tee -a "${_tmp_report_output}" || true

# ── Partition Growth Chart ───────────────────────────────────────────────────
_max_partitions=$(grep -E "^[[:space:]]*[0-9]+ [0-9.]+" health_report_partition_details.log 2>/dev/null | awk '{print $1}' | sort -rn | head -n 1 || echo 0)
if [[ "${_max_partitions}" -gt 1500 ]]; then
    gsc_log_info "High partition count detected (${_max_partitions}). Generating growth chart..."
    _part_json="supportLogs/partitionMap.json"
    [[ ! -f "${_part_json}" ]] && _part_json=$(find . -name partitionMap.json -print -quit 2>/dev/null || echo "")
    _pg_bin="${_script_dir}/partition_growth/build/partition_growth-linux-amd64"
    _pg_plot="${_script_dir}/partition_growth/plot.gp"
    if [[ -n "${_part_json}" && -f "${_part_json}" && -x "${_pg_bin}" && -f "${_pg_plot}" ]]; then
        if command -v gnuplot >/dev/null 2>&1; then
            "${_pg_bin}" -f "${_part_json}" -a > partition_growth_chart.log 2>/dev/null || true
            gnuplot "${_pg_plot}" >> partition_growth_chart.log 2>/dev/null || true
            if [[ -s partition_growth_chart.log ]]; then
                gsc_log_info "Partition growth charts and rates generated: partition_growth_chart.log"
                # If not reporting, print the summaries to the screen
                if [[ -z "${_report_file}" ]]; then
                    sed -n '/--- Yearly/,/Grand Total/p' partition_growth_chart.log
                fi
            fi
        else
            gsc_log_warn "gnuplot not found; skipping partition growth chart generation."
            # Still run the binary to get text-based rates if gnuplot is missing
            "${_pg_bin}" -f "${_part_json}" -a > partition_growth_chart.log 2>/dev/null || true
            if [[ -s partition_growth_chart.log ]]; then
                gsc_log_info "Partition growth rates generated (no charts): partition_growth_chart.log"
                if [[ -z "${_report_file}" ]]; then
                    sed -n '/--- Yearly/,/Grand Total/p' partition_growth_chart.log
                fi
            fi
        fi
    else
        gsc_log_warn "Missing partition_growth artifacts or JSON; skipping growth rate calculation."
    fi
fi

gsc_log_info "# RUN chk_buckets.sh"
"${_script_dir}/chk_buckets.sh" --bucket-owner 2>&1 | tee -a "${_tmp_report_output}" || true

gsc_log_info "# RUN parse_instances_info.sh"
"${_script_dir}/parse_instances_info.sh" 2>&1 | tee -a "${_tmp_report_output}" || true

if [[ "${_full_detail}" -eq 1 ]]; then
    gsc_log_info "# RUN chk_disk_perf.sh"
    "${_script_dir}/chk_disk_perf.sh" -d . 2>&1 | tee -a "${_tmp_report_output}" || true
    gsc_log_info "# RUN chk_filesystem.sh"
    "${_script_dir}/chk_filesystem.sh" -d . 2>&1 | tee -a "${_tmp_report_output}" || true
    gsc_log_info "# RUN chk_messages.sh"
    "${_script_dir}/chk_messages.sh" -d . 2>&1 | tee -a "${_tmp_report_output}" || true
    gsc_log_info "# RUN chk_docker.sh"
    "${_script_dir}/chk_docker.sh" -d . 2>&1 | tee -a "${_tmp_report_output}" || true
fi

gsc_log_info "# RUN chk_alerts.sh"
"${_script_dir}/chk_alerts.sh" 2>&1 | tee -a "${_tmp_report_output}" || true

gsc_log_info "# RUN chk_services_sh.sh"
"${_script_dir}/chk_services_sh.sh" 2>&1 | tee -a "${_tmp_report_output}" || true

gsc_log_info "# RUN chk_snodes.sh"
"${_script_dir}/chk_snodes.sh" 2>&1 | tee -a "${_tmp_report_output}" || true

gsc_log_info "# RUN chk_services_memory.sh"
"${_script_dir}/chk_services_memory.sh" 2>&1 | tee -a "${_tmp_report_output}" || true

if [[ "${_no_metrics}" -eq 0 ]]; then
    # Prefer values from healthcheck.conf if they were sourced, otherwise fallback to defaults
    _prom_host="${_prom_server:-${PROM_CMD_PARAM_DAILY:-}}"
    _prom_p="${_prom_port:-9090}"
    
    if [[ -n "${_prom_host}" ]]; then
        if [[ -n "${PROM_CMD_PARAM_HOURLY:-}" ]]; then
            gsc_log_info "# RUN chk_metrics.sh (using PROM_CMD_PARAM_HOURLY from ${_config_file})"
            IFS=' ' read -ra _chk_metrics_args <<< "${PROM_CMD_PARAM_HOURLY}"
            # Fix json path: if the specified file doesn't exist, look for it alongside the scripts
            for _ci in "${!_chk_metrics_args[@]}"; do
                if [[ "${_chk_metrics_args[$_ci]}" == *.json && ! -f "${_chk_metrics_args[$_ci]}" ]]; then
                    _fallback="${_script_dir}/$(basename -- "${_chk_metrics_args[$_ci]}")"
                    [[ -f "${_fallback}" ]] && _chk_metrics_args[$_ci]="${_fallback}"
                fi
            done
            "${_script_dir}/chk_metrics.sh" "${_chk_metrics_args[@]}" 2>&1 | tee -a "${_tmp_report_output}" || true
        else
            gsc_log_info "# RUN chk_metrics.sh on ${_prom_host}:${_prom_p}"
            "${_script_dir}/chk_metrics.sh" -c "${_prom_host}" -n "${_prom_p}" 2>&1 | tee -a "${_tmp_report_output}" || true
        fi
    else
        gsc_log_warn "# SKIP chk_metrics.sh: Prometheus host not found in ${_config_file}"
    fi
fi

# ── Final Report ─────────────────────────────────────────────────────────────
if [[ -n "${_report_file}" ]]; then
    "${_script_dir}/generate_report.sh" -o "${_report_file}" -d .
fi

# ── Final Summary ────────────────────────────────────────────────────────────
_end_epoch=$(date -u +%s)
_elapsed=$(( _end_epoch - _current_time_epoch ))

_issues_filter='^health_report_messages\.log:|: source [^ ]+ (unreachable|degraded)|: only [0-9]+ of [0-9]+ source.s. fully reachable|^[[:space:]]*[0-9]+ [0-9.]+[[:space:]]*\[(CRITICAL|WARNING|DANGER|good)\]'
_all_issues=$(grep -hE "ERROR|WARNING|CRITICAL|ACTION|ALERT" health_report*.log 2>/dev/null | grep -Ev "${_issues_filter}" || true)
_issues_count=$(printf '%s\n' "${_all_issues}" | grep -c . 2>/dev/null || echo 0)

gsc_log_info "++++++++++++++++++++++++++++++++++++++++"
gsc_log_info "SUMMARY: ${_issues_count} issue(s) found | Elapsed: ${_elapsed}s"
gsc_log_info "++++++++++++++++++++++++++++++++++++++++"

_critical_issues=$(printf '%s\n' "${_all_issues}" | grep -E "CRITICAL|ALERT" | sed 's/^health_report_[^:]*://' || true)
_error_issues=$(printf '%s\n' "${_all_issues}" | grep "ERROR" | grep -vE "CRITICAL|ALERT" | sed 's/^health_report_[^:]*://' || true)
_warning_issues=$(printf '%s\n' "${_all_issues}" | grep "WARNING" | grep -vE "CRITICAL|ALERT|ERROR" | sed 's/^health_report_[^:]*://' || true)
_action_issues=$(printf '%s\n' "${_all_issues}" | grep "ACTION" | grep -vE "CRITICAL|ALERT|ERROR|WARNING" | sed 's/^health_report_[^:]*://' || true)

if [[ -n "${_critical_issues}" ]]; then
    gsc_log_info "++++++++++ CRITICAL / ALERT ++++++++++"
    while IFS= read -r _ln; do [[ -n "${_ln}" ]] && gsc_log_critical "${_ln}"; done <<< "${_critical_issues}"
fi
if [[ -n "${_error_issues}" ]]; then
    gsc_log_info "++++++++++ ERROR ++++++++++"
    while IFS= read -r _ln; do [[ -n "${_ln}" ]] && gsc_log_error "${_ln}"; done <<< "${_error_issues}"
fi
if [[ -n "${_warning_issues}" ]]; then
    gsc_log_info "++++++++++ WARNING ++++++++++"
    while IFS= read -r _ln; do [[ -n "${_ln}" ]] && gsc_log_warn "${_ln}"; done <<< "${_warning_issues}"
fi
if [[ -n "${_action_issues}" ]]; then
    gsc_log_info "++++++++++ ACTION ++++++++++"
    while IFS= read -r _ln; do [[ -n "${_ln}" ]] && gsc_log_action "${_ln}"; done <<< "${_action_issues}"
fi

gsc_log_success "Checks complete. Logs available in current directory."
rm -f "${_tmp_report_output}"
