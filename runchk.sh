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
_full_detail=0   # --full-detail : run chk_disk_perf, chk_filesystem, chk_messages
_no_metrics=0    # --no-metrics  : skip chk_metrics.sh

# ── Usage ────────────────────────────────────────────────────────────────────
usage() {
    echo "\
Run the full HCP Cloud Scale health check suite.

Usage: runchk.sh [-f healthcheck.conf] [--full-detail] [--no-metrics] [-h]

  -f <file>       Path to healthcheck.conf (default: healthcheck.conf in the
                  current directory).  Also accepted as a bare positional
                  argument for backward compatibility.

  --full-detail   Include the three data-intensive checks that are skipped by
                  default:
                    chk_disk_perf.sh   — iostat device utilisation / latency
                    chk_filesystem.sh  — df usage, lsblk layout, LVM PV/VG
                    chk_messages.sh    — journald error/warning analysis

  --no-metrics    Skip chk_metrics.sh (Prometheus query suite).  Useful when
                  no Prometheus container is running or the port is unknown.

  -h, --help      Show this help and exit.
"
}

# ── Option parsing ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        -f)
            [[ -z "${2-}" ]] && { gsc_log_error "-f requires a filename"; exit 1; }
            _config_file="$2"; shift 2 ;;
        --full-detail)
            _full_detail=1; shift ;;
        --no-metrics)
            _no_metrics=1; shift ;;
        -h|--help)
            usage; exit 0 ;;
        -*)
            gsc_log_error "Unknown option: $1"; usage; exit 1 ;;
        *)
            # Backward-compatible: bare positional argument is the config file
            _config_file="$1"; shift ;;
    esac
done

# ── Load config ──────────────────────────────────────────────────────────────
# Ensure bash's . command finds the file in CWD rather than searching PATH
[[ "${_config_file}" != */* ]] && _config_file="./${_config_file}"
if [[ ! -f ${_config_file} ]]; then
    echo "WARNING: cannot find ${_config_file}. Skipping Prometheus-dependent checks."
else
    # shellcheck disable=SC1090
    . "${_config_file}"
fi

# ── Run ──────────────────────────────────────────────────────────────────────
echo "========= RUN ALL CHECKS ========="
gsc_log_info "========= RUN ALL CHECKS ========="
gsc_log_info "Config: ${_config_file} | full-detail: ${_full_detail} | no-metrics: ${_no_metrics}"

# Pre-run bundle self-check
gsc_log_info "# RUN selfcheck.sh"
"${_script_dir}/selfcheck.sh"

gsc_log_info "# RUN print_cluster_identity_summary.sh"
"${_script_dir}/print_cluster_identity_summary.sh"

gsc_log_info "# RUN print_node_memory_summary.sh"
"${_script_dir}/print_node_memory_summary.sh"

gsc_log_info "# RUN print_node_os_summary.sh"
"${_script_dir}/print_node_os_summary.sh"

gsc_log_info "# RUN chk_cluster.sh"
"${_script_dir}/chk_cluster.sh"

gsc_log_info "# RUN chk_lshw.sh"
"${_script_dir}/chk_lshw.sh" -d .

gsc_log_info "# RUN chk_chrony.sh"
"${_script_dir}/chk_chrony.sh" -d .

gsc_log_info "# RUN chk_top.sh"
"${_script_dir}/chk_top.sh" -d .

gsc_log_info "# RUN prep_partitions_json.sh"
"${_script_dir}/prep_partitions_json.sh"

gsc_log_info "# RUN get_partition_tool_info.sh"
"${_script_dir}/get_partition_tool_info.sh"

gsc_log_info "# RUN chk_partInfo.sh"
"${_script_dir}/chk_partInfo.sh" -d .

gsc_log_info "# RUN get_partition_details.sh"
"${_script_dir}/get_partition_details.sh" . | tee health_report_partition_details.log

gsc_log_info "# RUN chk_buckets.sh"
"${_script_dir}/chk_buckets.sh" --bucket-owner
if [[ -f health_report_buckets.log ]]; then
    cat health_report_buckets.log
fi

gsc_log_info "# RUN parse_instances_info.sh"
"${_script_dir}/parse_instances_info.sh"


# ── Full-detail checks (opt-in) ──────────────────────────────────────────────
if [[ "${_full_detail}" -eq 1 ]]; then
    gsc_log_info "# RUN chk_disk_perf.sh"
    "${_script_dir}/chk_disk_perf.sh" -d .

    gsc_log_info "# RUN chk_filesystem.sh"
    "${_script_dir}/chk_filesystem.sh" -d .

    gsc_log_info "# RUN chk_messages.sh"
    "${_script_dir}/chk_messages.sh" -d .

    gsc_log_info "# RUN chk_docker.sh"
   "${_script_dir}/chk_docker.sh" -d .
else
    gsc_log_info "# SKIP chk_disk_perf.sh, chk_filesystem.sh, chk_messages.sh chk_docker.sh (pass --full-detail to enable)"
fi

gsc_log_info "# RUN chk_alerts.sh"
"${_script_dir}/chk_alerts.sh"

gsc_log_info "# RUN chk_services_sh.sh -r '${VERSION_NUM:-}'"
"${_script_dir}/chk_services_sh.sh" -r "${VERSION_NUM:-}"

gsc_log_info "# RUN chk_snodes.sh"
"${_script_dir}/chk_snodes.sh"

gsc_log_info "### RUN parse_services_memory.sh"
# "${_script_dir}/parse_services_memory.sh"

gsc_log_info "# RUN chk_services_memory.sh"
"${_script_dir}/chk_services_memory.sh"

# ── Metrics check (opt-out) ──────────────────────────────────────────────────
if [[ "${_no_metrics}" -eq 0 ]]; then
    gsc_log_info "# RUN chk_metrics.sh ${PROM_CMD_PARAM_DAILY:-}"
    # shellcheck disable=SC2086
    "${_script_dir}/chk_metrics.sh" ${PROM_CMD_PARAM_DAILY:-}
else
    gsc_log_info "# SKIP chk_metrics.sh (--no-metrics)"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
_date2=$(date)
gsc_log_info "Start time: ${_date1}, end time: ${_date2}"

_script_end_time=$(date -u +%s)
((_script_run_seconds=_script_end_time-_current_time_epoch))
gsc_log_info "Total run time: ${_script_run_seconds} sec"

gsc_log_info "================================================"
# Filter out per-node details that have consolidated summary equivalents
# Silences: 
#   - Individual node service script modifications
#   - Individual node NTP source details (but keeps 'X node(s) have only...' summaries)
#   - Individual node partition distribution counts
_issues_filter='^health_report_messages\.log:|was modified on node [^ ]+|: source [^ ]+ (unreachable|degraded)|: only [0-9]+ of [0-9]+ source(s) fully reachable|^  [0-9]+ [0-9.]+ \[(CRITICAL|WARNING|DANGER|good)\]'

_issues_count=$(grep -E "ERROR|WARNING|CRITICAL|ACTION|ALERT" health_report*.log | grep -Ev "${_issues_filter}" | wc -l)
gsc_log_info "Detected the following ${_issues_count} issue(s) (sorted by severity; refer to logs for node-level details):"

# Get all raw lines first
_raw_issues=$(grep -E "ERROR|WARNING|CRITICAL|ACTION|ALERT" health_report*.log | grep -Ev "${_issues_filter}" || true)

if [[ -n "${_raw_issues}" ]]; then
    # Pass 1: CRITICAL and ALERT (Highest Priority)
    printf '%s\n' "${_raw_issues}" | grep -E "CRITICAL|ALERT" | while IFS= read -r _line; do
        _msg=$(echo "${_line}" | sed 's/^health_report_[^:]*://')
        gsc_log_critical "${_msg}"
    done

    # Pass 2: ERROR
    printf '%s\n' "${_raw_issues}" | grep "ERROR" | grep -v "CRITICAL" | while IFS= read -r _line; do
        _msg=$(echo "${_line}" | sed 's/^health_report_[^:]*://')
        gsc_log_error "${_msg}"
    done

    # Pass 3: WARNING
    printf '%s\n' "${_raw_issues}" | grep "WARNING" | grep -vE "CRITICAL|ERROR" | while IFS= read -r _line; do
        _msg=$(echo "${_line}" | sed 's/^health_report_[^:]*://')
        gsc_log_warn "${_msg}"
    done

    # Pass 4: ACTION
    printf '%s\n' "${_raw_issues}" | grep "ACTION" | grep -vE "CRITICAL|ERROR|WARNING" | while IFS= read -r _line; do
        _msg=$(echo "${_line}" | sed 's/^health_report_[^:]*://')
        gsc_log_action "${_msg}"
    done
fi
