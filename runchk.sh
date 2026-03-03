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
        -f) _config_file="$2"; shift 2 ;;
        --full-detail) _full_detail=1; shift ;;
        --no-metrics) _no_metrics=1; shift ;;
        --report) _report_file="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*) gsc_log_error "Unknown option: $1"; usage; exit 1 ;;
        *) _config_file="$1"; shift ;;
    esac
done

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
        fi
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
    gsc_log_info "# RUN chk_metrics.sh"
    "${_script_dir}/chk_metrics.sh" ${PROM_CMD_PARAM_DAILY:-} 2>&1 | tee -a "${_tmp_report_output}" || true
fi

# ── Final Report ─────────────────────────────────────────────────────────────
if [[ -n "${_report_file}" ]]; then
    "${_script_dir}/generate_report.sh" -o "${_report_file}" -d .
fi

gsc_log_success "Checks complete. Logs available in current directory."
rm -f "${_tmp_report_output}"
