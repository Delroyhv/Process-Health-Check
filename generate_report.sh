#!/usr/bin/env bash
#
# generate_report.sh - Aggregates GSC health check logs into a Markdown report
#
# Usage: ./generate_report.sh [options]
#

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${_script_dir}/gsc_core.sh"

_report_file="health_report.md"
_log_dir="."
_chart_sections=""

usage() {
    echo "Usage: $0 [-o report.md] [-d log_directory] [--chart yearly,quarterly,monthly]"
    echo "  -o <file>        Output Markdown file (default: health_report.md)"
    echo "  -d <dir>         Directory containing health_report_*.log files (default: .)"
    echo "  --chart <secs>   Comma-separated chart sections to include (yearly, quarterly, monthly)"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) _report_file="$2"; shift 2 ;;
        -d) _log_dir="$2";     shift 2 ;;
        --chart) _chart_sections="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) usage ;;
    esac
done

cd "${_log_dir}" || exit 1

# 1. Extract Summary Variables from logs
_cluster_serial=$(grep -h "Cluster serial (from cluster.serial):" health_report_*.log 2>/dev/null | head -n 1 | cut -d: -f2- | xargs || echo "N/A")
_cluster_name=$(grep -h "Cluster name   (from cluster.name):" health_report_*.log 2>/dev/null | head -n 1 | cut -d: -f2- | xargs || echo "N/A")
_total_nodes=$(grep -h "Total node count:" health_report_*.log 2>/dev/null | head -n 1 | cut -d: -f2 | xargs || echo "N/A")
_total_memory=$(grep -h "Total memory:" health_report_*.log 2>/dev/null | head -n 1 | cut -d: -f2 | xargs || echo "N/A")
_os_version=$(grep -h "OS version:" health_report_*.log 2>/dev/null | head -n 1 | cut -d: -f2- | xargs || echo "N/A")
_cs_version=$(grep -h "Cloud Scale Version:" health_report_*.log 2>/dev/null | head -n 1 | cut -d: -f2- | xargs || echo "N/A")
_server_model=$(grep -h "Server Model (Consolidated):" health_report_*.log 2>/dev/null | tail -n +2 | sed 's/^[[:space:]]*- //g' | sed 's/node(s) with model: //g' | tr '\n' ';' | sed 's/;$//' || echo "N/A")

_mdgw_nodes=$(grep -h "MDGW instances:" health_report_services_instances.log 2>/dev/null | cut -d: -f2 | xargs || echo "N/A")
_s3_nodes=$(grep -h "S3GW instances:" health_report_services_instances.log 2>/dev/null | cut -d: -f2 | xargs || echo "N/A")
_dls_nodes=$(grep -h "DLS instances:" health_report_services_instances.log 2>/dev/null | cut -d: -f2 | xargs || echo "N/A")

_issues_filter='^health_report_messages\.log:|was modified on node [^ ]+|: source [^ ]+ (unreachable|degraded)|: only [0-9]+ of [0-9]+ source(s) fully reachable|^[[:space:]]*[0-9]+ [0-9.]+\s*\[(CRITICAL|WARNING|DANGER|good)\]'
_issues_count=$(grep -E "ERROR|WARNING|CRITICAL|ACTION|ALERT" health_report*.log 2>/dev/null | grep -Evc "${_issues_filter}" || echo 0)

# Metrics specific summary
_metric_logs=()
for _f in health_report_metrics_*.log; do
    [[ -f "$_f" ]] && _metric_logs+=("$_f")
done
_m_critical=0
_m_error=0
_m_warning=0
_m_alert=0

if [[ ${#_metric_logs[@]} -gt 0 ]]; then
    _m_critical=$(grep -hc "CRITICAL" "${_metric_logs[@]}")
    _m_error=$(grep -h "ERROR" "${_metric_logs[@]}" | grep -vc "CRITICAL")
    _m_warning=$(grep -hc "WARNING" "${_metric_logs[@]}")
    _m_alert=$(grep -hc "ALERT" "${_metric_logs[@]}")
fi

# 2. Generate Markdown
{
    echo "# GSC Health Check Report"
    echo "Generated on: $(date)"
    echo ""
    echo "## 1. Summary"
    echo ""
    echo "| Metric | Value |"
    echo "|---|---|"
    echo "| Cluster Name | ${_cluster_name} |"
    echo "| Cluster Serial | ${_cluster_serial} |"
    echo "| Cloud Scale Version | ${_cs_version} |"
    echo "| OS Version | ${_os_version} |"
    echo "| Total Nodes | ${_total_nodes} |"
    echo "| Total Memory | ${_total_memory} |"
    echo "| Nodes MDGW | ${_mdgw_nodes} |"
    echo "| Nodes S3 | ${_s3_nodes} |"
    echo "| Nodes DLS | ${_dls_nodes} |"
    echo "| Server Model | ${_server_model} |"
    echo "| Total Issues Detected | ${_issues_count} |"
    echo ""

    echo "## 2. Metrics Summary (Prometheus)"
    echo ""
    echo "| Severity | Count |"
    echo "|---|---|"
    echo "| CRITICAL | ${_m_critical} |"
    echo "| ERROR | ${_m_error} |"
    echo "| WARNING | ${_m_warning} |"
    echo "| ALERT | ${_m_alert} |"
    echo ""

    echo "## 3. Issues Detected"
    echo '```text'
    _report_issues=$(grep -E "ERROR|WARNING|CRITICAL|ACTION|ALERT" health_report*.log 2>/dev/null | grep -Ev "${_issues_filter}" || true)
    if [[ -n "${_report_issues}" ]]; then
        printf '%s\n' "${_report_issues}" | grep -E "CRITICAL|ALERT" | sed 's/^health_report_[^:]*://'
        printf '%s\n' "${_report_issues}" | grep "ERROR" | grep -vE "CRITICAL|ALERT" | sed 's/^health_report_[^:]*://'
        printf '%s\n' "${_report_issues}" | grep "WARNING" | grep -vE "CRITICAL|ALERT|ERROR" | sed 's/^health_report_[^:]*://'
        printf '%s\n' "${_report_issues}" | grep "ACTION" | grep -vE "CRITICAL|ALERT|ERROR|WARNING" | sed 's/^health_report_[^:]*://'
    else
        echo "No significant issues detected."
    fi
    echo '```'
    echo ""

    echo "## 4. Partition Analysis"
    if [[ -n "${_chart_sections}" && -f "partition_splits.log" ]]; then
        echo "### Growth Trends"
        echo '```text'
        for _sec in yearly quarterly monthly; do
            [[ ",${_chart_sections}," == *",${_sec},"* ]] || continue
            case "${_sec}" in
                yearly)    _hdr="--- Yearly Partition Growth ---" ;;
                quarterly) _hdr="--- Quarterly Partition Growth ---" ;;
                monthly)   _hdr="--- Monthly Partition Growth ---" ;;
            esac
            awk -v h="${_hdr}" 'found && /^--- / {exit} $0==h{found=1} found' partition_splits.log
            echo ""
        done
        echo '```'
    fi

    _part_details="health_report_partition_details.log"
    if [[ -f "${_part_details}" ]]; then
        echo "### Density Details"
        echo '```text'
        echo "Nodes > 1500 Partitions:"
        grep -E "^[[:space:]]*[0-9]+ [0-9.]+\s*\[(DANGER|CRITICAL)\]" "${_part_details}" | sed 's/^\s*//' || echo "None"
        echo ""
        echo "Nodes approaching 900 Partitions:"
        grep -E "^[[:space:]]*[0-9]+ [0-9.]+\s*\[(WARNING|DANGER|CRITICAL)\]" "${_part_details}" | awk '$1 >= 900' | sed 's/^\s*//' || echo "None"
        echo '```'
    fi
} > "${_report_file}"

gsc_log_ok "Report generated: ${_report_file}"
