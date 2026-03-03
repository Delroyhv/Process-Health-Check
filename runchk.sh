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
_report_file=""  # --report : generate markdown report
_partition_details_log="health_report_partition_details.log" # Used for report generation

# ── Usage ────────────────────────────────────────────────────────────────────
usage() {
    echo "\
Run the full HCP Cloud Scale health check suite.

Usage: runchk.sh [-f healthcheck.conf] [--full-detail] [--no-metrics] [--report report.md] [-h]

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

  --report <file> Generate a Markdown report to the specified file.
                  If set, summary output is redirected to this file.

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
        --report)
            [[ -z "${2-}" ]] && { gsc_log_error "--report requires a filename"; exit 1; }
            _report_file="$2"; shift 2 ;;
        -h|--help)
            usage; exit 0 ;;
        -*)
            gsc_log_error "Unknown option: $1"; usage; exit 1 ;;
        *)
            _config_file="$1"; shift ;;
    esac
done

# If report is enabled, redirect stdout for logging
if [[ -n "${_report_file}" ]]; then
    # Create a temporary file to capture all output
    _tmp_report_output=$(mktemp)
    exec > >(tee "${_tmp_report_output}") 2>&1
    gsc_log_info "Generating report: ${_report_file}"
fi

# ── Run ──────────────────────────────────────────────────────────────────────
echo "========= RUN ALL CHECKS ========="
gsc_log_info "========= RUN ALL CHECKS ========="
gsc_log_info "Config: ${_config_file} | full-detail: ${_full_detail} | no-metrics: ${_no_metrics} | report: ${_report_file:-None}"

# Pre-run bundle self-check
gsc_log_info "# RUN selfcheck.sh"
"${_script_dir}/selfcheck.sh"

gsc_log_info "# RUN print_cluster_identity_summary.sh"
"${_script_dir}/print_cluster_identity_summary.sh"
# Capture cluster identity details
_cluster_serial=$(grep "Cluster serial" "${_tmp_report_output}" | head -n 1 | cut -d: -f2- | xargs || echo "N/A")
_cluster_name=$(grep "Cluster name" "${_tmp_report_output}" | head -n 1 | cut -d: -f2- | xargs || echo "N/A")

gsc_log_info "# RUN print_node_memory_summary.sh"
"${_script_dir}/print_node_memory_summary.sh"
# Capture total nodes and memory
_total_nodes=$(grep "Total node count:" "${_tmp_report_output}" | head -n 1 | cut -d: -f2 | xargs || echo "N/A")
_total_memory=$(grep "Total memory:" "${_tmp_report_output}" | head -n 1 | cut -d: -f2 | xargs || echo "N/A")

gsc_log_info "# RUN print_node_os_summary.sh"
"${_script_dir}/print_node_os_summary.sh"
# Capture OS Version (first unique OS detected)
_os_version=$(grep "OS version:" "${_tmp_report_output}" | head -n 1 | cut -d: -f2- | xargs || echo "N/A")

gsc_log_info "# RUN chk_cluster.sh"
"${_script_dir}/chk_cluster.sh"
# Capture Cloud Scale Version
_cs_version=$(grep "Cloud Scale Version:" "${_tmp_report_output}" | head -n 1 | cut -d: -f2- | xargs || echo "N/A")


gsc_log_info "# RUN chk_lshw.sh"
"${_script_dir}/chk_lshw.sh" -d .
# Capture Server Model (Consolidated)
_server_model=$(grep "Server Model (Consolidated):" "${_tmp_report_output}" | tail -n +2 | sed 's/^[[:space:]]*- //g' | sed 's/node(s) with model: //g' | tr '\n' ';' | sed 's/;$//' || echo "N/A")


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
"${_script_dir}/get_partition_details.sh" . | tee "${_partition_details_log}"

# ── Partition Growth Chart (conditional) ─────────────────────────────────────
_max_partitions=$(grep -E "^[[:space:]]*[0-9]+ [0-9.]+" "${_partition_details_log}" | awk '{print $1}' | sort -rn | head -n 1 || echo 0)
if [[ "${_max_partitions}" -gt 1500 ]]; then
    gsc_log_info "High partition count detected (${_max_partitions}). Generating growth chart..."
    _part_json="supportLogs/partitionMap.json"
    # Fallback if supportLogs/ is not in CWD
    [[ ! -f "${_part_json}" ]] && _part_json=$(find . -name partitionMap.json -print -quit 2>/dev/null || echo "")
    
    _pg_bin="${_script_dir}/partition_growth/build/partition_growth-linux-amd64"
    _pg_plot="${_script_dir}/partition_growth/plot.gp"

    if [[ -n "${_part_json}" && -f "${_part_json}" && -x "${_pg_bin}" && -f "${_pg_plot}" ]]; then
        if command -v gnuplot >/dev/null 2>&1; then
            # Run from script dir to ensure plot.gp can find its data if it uses relative paths
            # but output to CWD
            "${_pg_bin}" -f "${_part_json}" -a > partition_growth_chart.log 2>/dev/null || true
            gnuplot "${_pg_plot}" >> partition_growth_chart.log 2>/dev/null || true
            if [[ -s partition_growth_chart.log ]]; then
                gsc_log_info "Partition growth charts generated: partition_growth_chart.log"
                # Only print the Quarterly chart to screen unless reporting
                if [[ -z "${_report_file}" ]]; then
                    sed -n '/Quarterly Partition Growth/,/Weekly Growth/ { /Weekly Growth/!p }' partition_growth_chart.log
                fi
            fi
        else
            gsc_log_warn "gnuplot not found; skipping partition growth chart generation."
        fi
    else
        gsc_log_warn "Missing partition_growth artifacts or JSON; skipping chart generation."
    fi
fi

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
#   - Individual node NTP source details (but keeps 'X node(s) have...' summaries)
#   - Individual node partition distribution counts
_issues_filter='^health_report_messages\.log:|was modified on node [^ ]+|: source [^ ]+ (unreachable|degraded)|: only [0-9]+ of [0-9]+ source(s) fully reachable|^[[:space:]]*[0-9]+ [0-9.]+\s*\[(CRITICAL|WARNING|DANGER|good)\]'

_issues_count=$(grep -E "ERROR|WARNING|CRITICAL|ACTION|ALERT" health_report*.log | grep -Ev "${_issues_filter}" | wc -l)

if [[ -n "${_report_file}" ]]; then
    # Filtered and formatted raw issues as in the prompt
    _report_issues=$(
        grep -E "ERROR|WARNING|CRITICAL|ACTION|ALERT" health_report*.log | grep -Ev "${_issues_filter}" || true
    )
    
    # Generate the Markdown content
    local _md_content
    _md_content=$(
        echo "# Health Check Report"
        echo ""
        echo "## Summary"
        echo ""
        echo "| Metric | Value |"
        echo "|---|---|"
        echo "| Cluster Name | ${_cluster_name} |"
        echo "| Cluster Serial | ${_cluster_serial} |"
        echo "| Cloud Scale Version | ${_cs_version} |"
        echo "| OS Version | ${_os_version} |"
        echo "| Total Nodes | ${_total_nodes} |"
        echo "| Total Memory | ${_total_memory} |"
        echo "| Server Model | ${_server_model} |"
        echo "| Total Issues Detected | ${_issues_count} |"
        echo "| Start Time | ${_date1} |"
        echo "| End Time | ${_date2} |"
        echo "| Total Run Time | ${_script_run_seconds} sec |"
        echo ""

        echo "## Issues Detected"
        echo ""
        # The prompt implies a concise summary first, then a detailed list.
        # This section will just contain the requested raw issue lines.
        echo '```text'
        # Filtered, colored issues
        if [[ -n "${_report_issues}" ]]; then
            # Sorting by severity (CRITICAL/ALERT > ERROR > WARNING > ACTION)
            {
                printf '%s\n' "${_report_issues}" | grep -E "CRITICAL|ALERT" | sed 's/^health_report_[^:]*://' | sed -E 's/^(CRITICAL|ALERT)(.*)$/\x1b[31m\1\x1b[0m\2/'
                printf '%s\n' "${_report_issues}" | grep "ERROR" | grep -vE "CRITICAL|ALERT" | sed 's/^health_report_[^:]*://' | sed -E 's/^(ERROR)(.*)$/\x1b[31m\1\x1b[0m\2/'
                printf '%s\n' "${_report_issues}" | grep "WARNING" | grep -vE "CRITICAL|ALERT|ERROR" | sed 's/^health_report_[^:]*://' | sed -E 's/^(WARNING)(.*)$/\x1b[33m\1\x1b[0m\2/'
                printf '%s\n' "${_report_issues}" | grep "ACTION" | grep -vE "CRITICAL|ALERT|ERROR|WARNING" | sed 's/^health_report_[^:]*://' | sed -E 's/^(ACTION)(.*)$/\x1b[36m\1\x1b[0m\2/'
            }
        else
            echo "No issues detected."
        fi
        echo '```'
        echo ""

        echo "## Partition Growth Analysis"
        echo ""
        echo '```text'
        # Display all charts to the report file
        if [[ -f "partition_growth_chart.log" ]]; then
            cat partition_growth_chart.log
        else
            echo "No partition growth charts generated."
        fi
        echo '```'
        echo ""

        echo "## Partition Density Analysis"
        echo ""
        echo '```text'
        # Page of nodes need to have 900 partitions per node and 500 per node.
        # If partition size is 1G show decrease of growth changed to 16G
        
        # Extract relevant data from health_report_partition_details.log
        if [[ -f "${_partition_details_log}" ]]; then
            echo "### Nodes with >1500 Partitions/Node (DANGER/CRITICAL)"
            grep -E "^[[:space:]]*[0-9]+ [0-9.]+\s*\[(DANGER|CRITICAL)\]" "${_partition_details_log}" | sed 's/^\s*//' || echo "None"
            echo ""

            echo "### Nodes approaching 900 Partitions/Node (WARNING or higher)"
            grep -E "^[[:space:]]*[0-9]+ [0-9.]+\s*\[(WARNING|DANGER|CRITICAL)\]" "${_partition_details_log}" | awk '$1 >= 900' | sed 's/^\s*//' || echo "None"
            echo ""

            echo "### Nodes approaching 500 Partitions/Node"
            grep -E "^[[:space:]]*[0-9]+ [0-9.]+" "${_partition_details_log}" | awk '$1 >= 500 && $1 < 900 && ($0 ~ "\\[(good|WARNING|DANGER|CRITICAL)\\]") {print $0}' | sed 's/^\s*//' || echo "None"
            echo ""

            echo "### Partition Size Impact (e.g., if 1G changed to 16G)"
            echo "*(Requires additional data sources to analyze historical size impact, not currently calculated.)*"
            echo ""
        else
            echo "Partition details log (health_report_partition_details.log) not found."
        fi
        echo '```'
        echo ""
    )
    # Write the Markdown content to the report file, preserving ANSI colors
    printf '%b\n' "${_md_content}" > "${_report_file}"
    rm -f "${_tmp_report_output}"

else
    gsc_log_info "Detected the following ${_issues_count} issue(s) (sorted by severity; refer to logs for node-level details):"

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
fi
