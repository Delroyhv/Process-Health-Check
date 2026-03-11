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
_chart_sections=""
_forecast_thresh_new=""

# ── Usage ────────────────────────────────────────────────────────────────────
usage() {
    echo "Usage: runchk.sh [-f healthcheck.conf] [--full-detail] [--no-metrics] [--report report.md] [--chart yearly,quarterly,monthly] [--forecast N] [-h]"
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
        --chart)
            if [[ -n "${2-}" ]]; then
                _chart_sections="$2"; shift 2
            else
                gsc_log_error "--chart requires a value (e.g. quarterly,yearly,monthly)"; exit 1
            fi
            ;;
        --forecast)
            if [[ -n "${2-}" ]]; then
                _forecast_thresh_new="$2"; shift 2
            else
                gsc_log_error "--forecast requires a threshold value in GB (e.g. --forecast 16)"; exit 1
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
# Fall back to CWD if /tmp is not writable (e.g. restrictive mount on customer systems)
_tmp_report_output=$(mktemp 2>/dev/null || TMPDIR=. mktemp)

# ── Run ──────────────────────────────────────────────────────────────────────
gsc_log_info "========= RUN ALL CHECKS ========="
gsc_log_info "Config: ${_config_file} | full-detail: ${_full_detail} | no-metrics: ${_no_metrics} | report: ${_report_file:-None}"

gsc_log_info "# RUN selfcheck.sh"
"${_script_dir}/selfcheck.sh" 2>&1 | tee -a "${_tmp_report_output}" || true

gsc_log_info "# RUN print_node_memory_summary.sh"
"${_script_dir}/print_node_memory_summary.sh" 2>&1 | tee -a "${_tmp_report_output}" || true

gsc_log_info "# RUN print_node_os_summary.sh"
"${_script_dir}/print_node_os_summary.sh" 2>&1 | tee -a "${_tmp_report_output}" || true

gsc_log_info "# RUN chk_cluster.sh"
"${_script_dir}/chk_cluster.sh" 2>&1 | tee -a "${_tmp_report_output}" || true

gsc_log_info "# RUN chk_lshw.sh"
"${_script_dir}/chk_lshw.sh" -d . 2>&1 | tee -a "${_tmp_report_output}" || true

gsc_log_info "# RUN parse_instances_info.sh"
"${_script_dir}/parse_instances_info.sh" 2>&1 | tee -a "${_tmp_report_output}" || true

gsc_log_info "# RUN prep_services_instances.sh"
"${_script_dir}/prep_services_instances.sh" . > health_report_services_instances.log 2>&1 || true
cat health_report_services_instances.log >> "${_tmp_report_output}"

gsc_log_info "# RUN print_cluster_identity_summary.sh"
"${_script_dir}/print_cluster_identity_summary.sh" 2>&1 | tee -a "${_tmp_report_output}" || true

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

gsc_log_info "# RUN chk_partition_sizes.sh"
"${_script_dir}/chk_partition_sizes.sh" -d . 2>&1 | tee -a "${_tmp_report_output}" || true

# ── Partition Growth Chart ───────────────────────────────────────────────────
# Run before get_partition_details.sh so avg_monthly_growth is available for sizing output.
_part_json="supportLogs/partitionSplit.json"
[[ ! -f "${_part_json}" ]] && _part_json=$(find . -name partitionSplit.json -print -quit 2>/dev/null || echo "")
_pg_bin="${_script_dir}/partition_growth/build/partition_growth-linux-amd64"
_pg_plot="${_script_dir}/partition_growth/plot.gp"
if [[ -n "${_part_json}" && -f "${_part_json}" && -x "${_pg_bin}" ]]; then
    "${_pg_bin}" -f "${_part_json}" -a > partition_growth_chart.log 2>/dev/null || true
    if command -v gnuplot >/dev/null 2>&1 && [[ -f "${_pg_plot}" ]]; then
        gnuplot "${_pg_plot}" > partition_growth_plot.log 2>/dev/null || true
        if [[ -s partition_growth_plot.log ]]; then
            gsc_log_info "Partition growth plots generated: partition_growth_plot.log"
        fi
    else
        {
            echo "Partition growth plots could not be generated."
            echo ""
            echo "Requirements to enable ASCII partition growth plots:"
            echo "  - gnuplot-nox  (install: sudo dnf install gnuplot-nox)"
            echo ""
            echo "The plot script used is: ${_pg_plot}"
            echo "Once gnuplot is installed, re-run runchk.sh to generate plots."
        } > partition_growth_plot.log
        gsc_log_warn "gnuplot not found — plot requirements logged to partition_growth_plot.log"
    fi
    if [[ -s partition_growth_chart.log ]]; then
        cp partition_growth_chart.log partition_splits.log
        gsc_log_info "Partition growth rates generated: partition_growth_chart.log (full detail: partition_splits.log)"
        if [[ -z "${_report_file}" ]]; then
            awk '/--- Quarterly Partition Growth ---/{p=1} /--- Monthly Partition Growth ---/{p=0} p' partition_splits.log
        fi
    fi
else
    gsc_log_warn "partitionSplit.json or partition_growth binary not found; skipping growth rate calculation."
fi

gsc_log_info "# RUN get_partition_details.sh"
"${_script_dir}/get_partition_details.sh" . 2>&1 | tee health_report_partition_details.log | tee -a "${_tmp_report_output}" || true

gsc_log_info "# RUN chk_buckets.sh"
"${_script_dir}/chk_buckets.sh" --bucket-owner 2>&1 | tee -a "${_tmp_report_output}" || true

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

gsc_log_info "# RUN chk_dls.sh"
"${_script_dir}/chk_dls.sh" -d . 2>&1 | tee -a "${_tmp_report_output}" || true

gsc_log_info "# RUN chk_services_memory.sh"
"${_script_dir}/chk_services_memory.sh" 2>&1 | tee -a "${_tmp_report_output}" || true

if [[ "${_no_metrics}" -eq 1 ]]; then
    gsc_log_warn "# SKIP chk_metrics.sh: Prometheus host not found in healthcheck.conf"
elif [[ "${_no_metrics}" -eq 0 ]]; then
    # Prefer values from healthcheck.conf if they were sourced, otherwise fallback to defaults
    _prom_host="${_prom_server:-${PROM_CMD_PARAM_DAILY:-}}"
    _prom_p="${_prom_port:-9090}"
    _prom_proto="${_prom_protocol:-http}"

    if [[ -z "${_prom_host}" ]]; then
        gsc_log_warn "# SKIP chk_metrics.sh: Prometheus host not found in healthcheck.conf"
    else
        # Probe Prometheus before running metrics checks
        _prom_reachable=0
        if curl -sf --max-time 5 "${_prom_proto}://${_prom_host}:${_prom_p}/-/ready" >/dev/null 2>&1; then
            _prom_reachable=1
        elif curl -sf --max-time 5 "http://${_prom_host}:${_prom_p}/-/ready" >/dev/null 2>&1; then
            _prom_reachable=1
        fi

        if [[ "${_prom_reachable}" -eq 0 ]]; then
            gsc_log_warn "# SKIP chk_metrics.sh: Prometheus at ${_prom_host}:${_prom_p} is not reachable"
        elif [[ -n "${PROM_CMD_PARAM_HOURLY:-}" ]]; then
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
    fi
fi

# ── Final Report ─────────────────────────────────────────────────────────────
if [[ -n "${_report_file}" ]]; then
    _report_args=(-o "${_report_file}" -d .)
    [[ -n "${_chart_sections}" ]] && _report_args+=(--chart "${_chart_sections}")
    [[ -n "${_forecast_thresh_new}" ]] && _report_args+=(--forecast "${_forecast_thresh_new}")
    "${_script_dir}/gsc_healthcheck_report.sh" "${_report_args[@]}"
fi

# ── Final Summary ────────────────────────────────────────────────────────────
_end_epoch=$(date -u +%s)
_elapsed=$(( _end_epoch - _current_time_epoch ))

_issues_filter='^health_report_messages\.log:|: source [^ ]+ (unreachable|degraded)|: only [0-9]+ of [0-9]+ source.s. fully reachable|^[[:space:]]*[0-9]+ [0-9.]+[[:space:]]*\[(CRITICAL|WARNING|DANGER|good)\]|^[[:space:]]*([0-9]+-[0-9]+|>=[[:space:]]*[0-9]+)[[:space:]]*:[[:space:]]*\[(WARNING|DANGER|CRITICAL|good)\]'
_all_issues=$(grep -hE "ERROR|WARNING|CRITICAL|DANGER|ACTION|ALERT" health_report*.log 2>/dev/null | grep -Ev "${_issues_filter}" || true)
_issues_count=$(printf '%s\n' "${_all_issues}" | grep -c . 2>/dev/null || echo 0)

# ── hcpcs_db: record run if HCPCS_DB is set ──────────────────────────────────
if [[ -n "${HCPCS_DB:-}" ]]; then
    _db_os=$(uname -s | tr '[:upper:]' '[:lower:]')
    _db_arch=$(uname -m)
    [[ "${_db_arch}" == "x86_64" ]]  && _db_arch="amd64"
    [[ "${_db_arch}" == "aarch64" ]] && _db_arch="arm64"
    _db_bin="${_script_dir}/hcpcs_db/build/hcpcs_db-${_db_os}-${_db_arch}"
    if [[ -x "${_db_bin}" ]]; then
        _db_args=(record --elapsed "${_elapsed}")
        [[ -n "${HCPCS_CUSTOMER:-}" ]] && _db_args+=(--customer "${HCPCS_CUSTOMER}")
        "${_db_bin}" "${_db_args[@]}" || true
    fi
fi

# Cluster identity header for final summary
_sum_serial=$(find cluster_triage -path "*/cluster_MAPI_infos/cluster.serial" \
              2>/dev/null | sort | head -n1)
if [[ -n "${_sum_serial}" && -f "${_sum_serial}" ]]; then
    _sum_serial=$(tr -d '[:space:]' < "${_sum_serial}")
    [[ -z "${_sum_serial}" ]] && _sum_serial="SN not defined"
else
    _sum_serial="SN not defined"
fi
_sum_name=$(find cluster_triage -path "*/cluster_MAPI_infos/cluster.name" \
            2>/dev/null | sort | head -n1)
if [[ -n "${_sum_name}" && -f "${_sum_name}" ]]; then
    _sum_name=$(tr -d '[:space:]' < "${_sum_name}")
    [[ -z "${_sum_name}" ]] && _sum_name="N/A"
else
    _sum_name="N/A"
fi
_sum_nodes=$(grep -h "Total nodes:" health_report_services*.log 2>/dev/null \
             | awk '{print $NF}' | grep -E "^[0-9]+$" | head -n1 || true)
_sum_mdgw=$(grep -h "MDGW instances:" health_report_services*.log 2>/dev/null \
            | awk '{print $NF}' | grep -E "^[0-9]+$" | head -n1 || true)
_sum_s3=$(grep -h "S3GW instances:" health_report_services*.log 2>/dev/null \
          | awk '{print $NF}' | grep -E "^[0-9]+$" | head -n1 || true)
_sum_dls=$(grep -h "DLS instances:" health_report_services*.log 2>/dev/null \
           | awk '{print $NF}' | grep -E "^[0-9]+$" | head -n1 || true)
_sum_nodes="${_sum_nodes:-N/A}"; _sum_mdgw="${_sum_mdgw:-N/A}"
_sum_s3="${_sum_s3:-N/A}"; _sum_dls="${_sum_dls:-N/A}"

gsc_log_info "++++++++++++++++++++++++++++++++++++++++"
gsc_log_info "Serial Number : ${_sum_serial}"
gsc_log_info "Cluster Name  : ${_sum_name}"
gsc_log_info "Total Nodes   : ${_sum_nodes}"
gsc_log_info "MDGW          : ${_sum_mdgw}  |  S3: ${_sum_s3}  |  DLS: ${_sum_dls}"
gsc_log_info "++++++++++++++++++++++++++++++++++++++++"
gsc_log_info "SUMMARY: ${_issues_count} issue(s) found | Elapsed: ${_elapsed}s"
gsc_log_info "++++++++++++++++++++++++++++++++++++++++"

_critical_issues=$(printf '%s\n' "${_all_issues}" | grep -E "CRITICAL|ALERT" | sed 's/^health_report_[^:]*://' || true)
_danger_issues=$(printf '%s\n' "${_all_issues}" | grep "DANGER" | grep -vE "CRITICAL|ALERT" | sed 's/^health_report_[^:]*://' || true)
_error_issues=$(printf '%s\n' "${_all_issues}" | grep "ERROR" | grep -vE "CRITICAL|ALERT|DANGER" | sed 's/^health_report_[^:]*://' || true)
_warning_issues=$(printf '%s\n' "${_all_issues}" | grep "WARNING" | grep -vE "CRITICAL|ALERT|DANGER|ERROR" | sed 's/^health_report_[^:]*://' || true)
_action_issues=$(printf '%s\n' "${_all_issues}" | grep "ACTION" | grep -vE "CRITICAL|ALERT|DANGER|ERROR|WARNING" | sed 's/^health_report_[^:]*://' || true)

if [[ -n "${_critical_issues}" ]]; then
    gsc_log_info "++++++++++ CRITICAL / ALERT ++++++++++"
    while IFS= read -r _ln; do [[ -n "${_ln}" ]] && gsc_log_critical "${_ln}"; done <<< "${_critical_issues}"
fi
if [[ -n "${_danger_issues}" ]]; then
    gsc_log_info "++++++++++ DANGER ++++++++++"
    while IFS= read -r _ln; do [[ -n "${_ln}" ]] && gsc_log_error "${_ln}"; done <<< "${_danger_issues}"
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
