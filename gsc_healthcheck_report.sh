#!/usr/bin/env bash
#
# gsc_healthcheck_report.sh – Generates a styled Markdown or PDF health report
#                             from GSC health check logs.
#
# Usage: gsc_healthcheck_report.sh [-d dir] [-o outfile] [-f md|pdf] [--chart sections] [-h]
#

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${_script_dir}/gsc_core.sh"

# ── Defaults ──────────────────────────────────────────────────────────────────
_log_dir="."
_out_file="health_report.md"
_format="md"
_chart_sections=""
_forecast_thresh_new=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [-d dir] [-o outfile] [-f md|pdf] [--chart sections] [--forecast N] [-h]

  -d <dir>         Directory with health_report_*.log and lshw.log (default: .)
  -o <outfile>     Output file (default: health_report.md)
  -f md|pdf        Output format; auto-detected from -o extension if omitted
  --chart <secs>   Comma-separated chart sections to include in report
                   (yearly, quarterly, monthly; e.g. quarterly,yearly)
  --forecast N     Embed cluster growth forecast; N = proposed threshold in GB
                   (e.g. --forecast 16 to model a 1 GB -> 16 GB threshold increase)
  -h               Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d) _log_dir="$2";        shift 2 ;;
        -o) _out_file="$2";       shift 2 ;;
        -f) _format="$2";         shift 2 ;;
        --chart) _chart_sections="$2"; shift 2 ;;
        --forecast) _forecast_thresh_new="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage; exit 1 ;;
    esac
done

if [[ "${_format}" == "md" && "${_out_file}" == *.pdf ]]; then
    _format="pdf"
fi
[[ "${_format}" == "md" || "${_format}" == "pdf" ]] \
    || gsc_die "Unknown format '${_format}'. Use md or pdf."

cd "${_log_dir}" || gsc_die "Cannot cd to: ${_log_dir}"

# ── Data extraction ───────────────────────────────────────────────────────────

_find_serial() {
    local _f
    _f=$(find cluster_triage -path "*/cluster_MAPI_infos/cluster.serial" \
         2>/dev/null | sort | head -n 1)
    [[ -n "${_f}" && -f "${_f}" ]] && tr -d '[:space:]' < "${_f}" || echo "N/A"
}

_find_cluster_name() {
    local _f
    _f=$(find cluster_triage -path "*/cluster_MAPI_infos/cluster.name" \
         2>/dev/null | sort | head -n 1)
    [[ -n "${_f}" && -f "${_f}" ]] && tr -d '[:space:]' < "${_f}" || echo "N/A"
}

_parse_cs_version() {
    local _ver
    _ver=$(grep -h "HCP-CS version:" health_report_cluster.log 2>/dev/null \
           | grep -oE "[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?" | head -n 1)
    if [[ -z "${_ver}" ]]; then
        _ver=$(grep -h "product version " health_report_cluster.log 2>/dev/null \
               | grep -oE "[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?" | head -n 1)
    fi
    echo "${_ver:-N/A}"
}

# Strip ANSI codes and log-level prefix ( [INFO] / ESC[32m[INFO][0m forms )
_strip_log_prefix() {
    sed 's/\x1b\[[0-9;]*m//g; s/^\[[A-Z ]*\][[:space:]]*//'
}

_parse_node_count() {
    grep -h "Total nodes:" health_report_services*.log 2>/dev/null \
        | _strip_log_prefix | grep -oE "[0-9]+" | head -n 1 || echo "N/A"
}

_parse_service_count() {
    grep -h "${1} instances:" health_report_services*.log 2>/dev/null \
        | _strip_log_prefix | grep -oE "[0-9]+" | head -n 1 || echo "N/A"
}

# Parse Memory column from health_report_lshw.log → "7 x 256GiB" or "4 x 256GiB, 6 x 512GiB"
_build_memory_summary() {
    local _lshw="health_report_lshw.log"
    [[ -f "${_lshw}" ]] || { echo "N/A"; return; }
    awk 'NR > 2 && NF > 1 && $2 ~ /[0-9]+(GiB|MiB|TiB)/ { print $2 }' "${_lshw}" \
        | sort | uniq -c | sort -rn \
        | awk 'BEGIN { out="" }
               { sep=(out=="") ? "" : ", "; out=out sep $1 " x " $2 }
               END { print (out=="") ? "N/A" : out }'
}

# Parse lshw.log per-node blocks → tab-delimited: node TAB product TAB serial TAB bios
_parse_lshw_hardware() {
    local _lshw="lshw.log"
    [[ -f "${_lshw}" ]] || return
    awk '
    BEGIN { node=""; product=""; serial=""; bios=""; got_p=0; got_s=0; in_fw=0 }

    /^=== .+ ===$/ {
        if (node != "") printf "%s\t%s\t%s\t%s\n", node, product, serial, bios
        node=$0; sub(/^=== /,"",node); sub(/ ===$/, "",node)
        product=""; serial=""; bios=""; got_p=0; got_s=0; in_fw=0
        next
    }

    /[*]-firmware/                 { in_fw=1; next }
    /[*]-[a-z]/ && !/[*]-firmware/ { in_fw=0 }

    /[[:space:]]product:/ && !got_p {
        val=$0; sub(/^[[:space:]]*product:[[:space:]]*/,"",val)
        gsub(/ \([Dd]efault [Ss]tring\)/,"",val)
        gsub(/ [0-9][A-Z][A-Z0-9]*$/,"",val)
        gsub(/[[:space:]]+$/,"",val)
        product=val; got_p=1
    }

    /[[:space:]]serial:/ && !got_s {
        val=$0; sub(/^[[:space:]]*serial:[[:space:]]*/,"",val)
        gsub(/[[:space:]]+$/,"",val)
        serial=val; got_s=1
    }

    /[[:space:]]version:/ && in_fw && bios=="" {
        val=$0; sub(/^[[:space:]]*version:[[:space:]]*/,"",val)
        gsub(/[[:space:]]+$/,"",val)
        bios=val
    }

    END { if (node!="") printf "%s\t%s\t%s\t%s\n", node, product, serial, bios }
    ' "${_lshw}"
}

# Collect + severity-sort issues from health_report_*.log
_collect_issues() {
    local _f='^health_report_messages\.log:|was modified on node [^ ]+|: source [^ ]+ (unreachable|degraded)|: only [0-9]+ of [0-9]+ source.s. fully reachable|^[[:space:]]*[0-9]+ [0-9.]+[[:space:]]*\[(CRITICAL|WARNING|DANGER|good)\]'
    local _all
    _all=$(grep -hE "ERROR|WARNING|CRITICAL|ACTION|ALERT" health_report*.log 2>/dev/null \
           | grep -Ev "${_f}" | sed 's/^health_report_[^:]*://' || true)
    [[ -z "${_all}" ]] && return
    printf '%s\n' "${_all}" | grep -E "CRITICAL|ALERT"                           || true
    printf '%s\n' "${_all}" | grep  "ERROR"   | grep -vE "CRITICAL|ALERT"        || true
    printf '%s\n' "${_all}" | grep  "WARNING" | grep -vE "CRITICAL|ALERT|ERROR"  || true
    printf '%s\n' "${_all}" | grep  "ACTION"  | grep -vE "CRITICAL|ALERT|ERROR|WARNING" || true
}

_count_severity() {
    # grep -c always outputs the count (including 0) and exits 1 on no match.
    # Do NOT add || echo 0 — that would produce "0\n0" and break arithmetic.
    printf '%s\n' "${1}" | grep -cE "${2}" 2>/dev/null || true
}

# HTML-escape then add colour spans. Always use for <pre> blocks.
_colorize_pre() {
    sed \
        -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
        | sed \
        -e 's/CRITICAL/<span style="color:#ff4444;font-weight:bold">CRITICAL<\/span>/g' \
        -e 's/ALERT/<span style="color:#ff4444;font-weight:bold">ALERT<\/span>/g' \
        -e 's/DANGER/<span style="color:#ff8800;font-weight:bold">DANGER<\/span>/g' \
        -e 's/WARNING/<span style="color:#ffcc00;font-weight:bold">WARNING<\/span>/g' \
        -e 's/ERROR/<span style="color:#ff6666;font-weight:bold">ERROR<\/span>/g'
}

# Extract one named section from partition_splits.log (stop before next --- header)
_extract_chart_section() {
    local _header="$1" _file="$2"
    awk -v h="${_header}" 'found && /^--- / {exit} $0==h{found=1} found' "${_file}"
}

# Run cluster_forecast binary and return its output; empty if binary/data not available.
_run_forecast() {
    local _thresh_new="$1"
    local _os _arch _bin
    _os=$(uname -s | tr '[:upper:]' '[:lower:]')
    _arch=$(uname -m)
    [[ "${_arch}" == "x86_64" ]] && _arch="amd64"
    [[ "${_arch}" == "aarch64" ]] && _arch="arm64"
    _bin="${_script_dir}/cluster_forecast/build/cluster_forecast-${_os}-${_arch}"
    [[ -x "${_bin}" ]] || return 0
    [[ -f "partition_splits.log" ]] || return 0
    local _args=(--dir .)
    [[ -n "${_thresh_new}" ]] && _args+=(--threshold-new "${_thresh_new}")
    "${_bin}" "${_args[@]}" 2>/dev/null || true
}

# ── HTML page wrapper ─────────────────────────────────────────────────────────

_html_head() {
    cat <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>HCP-CS Health Report</title>
<style>
  body       { background:#1e1e1e; color:#e0e0e0; font-family:monospace;
               font-size:13px; margin:2em; line-height:1.5; }
  h1,h2,h3  { color:#a0cfff; border-bottom:1px solid #444; padding-bottom:4px; }
  table      { border-collapse:collapse; width:auto; margin-bottom:1.2em; }
  th         { background:#2d2d2d; color:#a0cfff; padding:5px 12px;
               text-align:left; border:1px solid #444; }
  td         { padding:4px 12px; border:1px solid #333; }
  tr:nth-child(even) td { background:#252525; }
  pre        { background:#141414; padding:1em; border-radius:4px;
               overflow-x:auto; white-space:pre-wrap; word-break:break-all; }
  .ok        { color:#66bb6a; }
  hr         { border:none; border-top:1px solid #444; margin:1.5em 0; }
</style>
</head>
<body>
EOF
}

_html_foot() { printf '</body>\n</html>\n'; }

# ── PDF generation ────────────────────────────────────────────────────────────

_to_pdf() {
    local _html="$1" _pdf="$2"
    if command -v wkhtmltopdf >/dev/null 2>&1; then
        wkhtmltopdf --quiet --enable-local-file-access "${_html}" "${_pdf}"
        return
    fi
    if command -v weasyprint >/dev/null 2>&1; then
        weasyprint "${_html}" "${_pdf}"
        return
    fi
    if command -v pandoc >/dev/null 2>&1 && command -v xelatex >/dev/null 2>&1; then
        pandoc "${_html}" -o "${_pdf}" --pdf-engine=xelatex
        return
    fi
    gsc_log_warn "PDF generation requires one of:"
    gsc_log_warn "  wkhtmltopdf  (rpm: wkhtmltopdf, deb: wkhtmltopdf)"
    gsc_log_warn "  weasyprint   (pip: weasyprint)"
    gsc_log_warn "  pandoc       (rpm: pandoc) + texlive-xetex"
    return 1
}

# ── Report body: Markdown ─────────────────────────────────────────────────────

_build_md() {
    local _serial _cluster _version _nodes _memory _mdgw _s3gw _dls
    _serial=$(_find_serial); _cluster=$(_find_cluster_name)
    _version=$(_parse_cs_version); _nodes=$(_parse_node_count)
    _memory=$(_build_memory_summary)
    _mdgw=$(_parse_service_count "MDGW"); _s3gw=$(_parse_service_count "S3GW")
    _dls=$(_parse_service_count "DLS")

    local _hw_data _hw_line="" _hw_table=""
    _hw_data=$(_parse_lshw_hardware)
    if [[ -n "${_hw_data}" ]]; then
        local _up _ub
        _up=$(printf '%s\n' "${_hw_data}" | cut -f2 | sort -u | wc -l)
        _ub=$(printf '%s\n' "${_hw_data}" | cut -f4 | sort -u | wc -l)
        if [[ "${_up}" -eq 1 && "${_ub}" -eq 1 ]]; then
            local _prod _bios
            _prod=$(printf '%s\n' "${_hw_data}" | cut -f2 | head -n 1)
            _bios=$(printf '%s\n' "${_hw_data}" | cut -f4 | head -n 1)
            _hw_line="All ${_nodes} nodes: ${_prod} | BIOS ${_bios}"
        else
            _hw_table=$(printf '%s\n' "${_hw_data}" | awk -F'\t' '
                BEGIN { print "| Node | Serial | Product | BIOS |"; print "|---|---|---|---|" }
                { printf "| %s | %s | %s | %s |\n", $1, $3, $2, $4 }')
        fi
    fi

    local _issues _n_crit _n_err _n_warn _n_act _n_total
    _issues=$(_collect_issues)
    _n_crit=$(_count_severity "${_issues}" "CRITICAL|ALERT")
    _n_err=$(_count_severity  "${_issues}" "ERROR")
    _n_warn=$(_count_severity "${_issues}" "WARNING")
    _n_act=$(_count_severity  "${_issues}" "ACTION")
    _n_total=$(( _n_crit + _n_err + _n_warn + _n_act ))

    # ── output ────────────────────────────────────────────────────────────────
    printf '# HCP-CS Health Check Report\n\n'
    printf 'Generated: %s\n\n---\n\n' "$(date)"

    printf '## 1. HCP-CS Cluster Identity\n\n'
    printf '| | |\n|---|---|\n'
    printf '| **Cluster Serial**    | %s |\n' "${_serial}"
    printf '| **Cluster Name**      | %s |\n' "${_cluster}"
    printf '| **CS Version**        | %s |\n' "${_version}"
    printf '| **Total Nodes**       | %s |\n' "${_nodes}"
    printf '| **Memory**            | %s |\n' "${_memory}"
    printf '| **MDGW / S3GW / DLS** | %s / %s / %s |\n\n' "${_mdgw}" "${_s3gw}" "${_dls}"

    if [[ -n "${_hw_line}" ]]; then
        printf '**Hardware:** %s\n\n' "${_hw_line}"
    elif [[ -n "${_hw_table}" ]]; then
        printf '**Hardware (mixed):**\n\n%s\n\n' "${_hw_table}"
    fi

    printf '## 2. Issues by Criticality\n\n'
    printf '| Severity | Count |\n|---|---|\n'
    printf '| <span style="color:#ff4444;font-weight:bold">CRITICAL / ALERT</span> | %s |\n' "${_n_crit}"
    printf '| <span style="color:#ff6666;font-weight:bold">ERROR</span> | %s |\n'            "${_n_err}"
    printf '| <span style="color:#ffcc00;font-weight:bold">WARNING</span> | %s |\n'          "${_n_warn}"
    printf '| ACTION | %s |\n'                                                               "${_n_act}"
    printf '| **Total** | **%s** |\n\n' "${_n_total}"

    if [[ "${_n_total}" -eq 0 ]]; then
        printf '<span style="color:#66bb6a">No significant issues detected.</span>\n\n'
    else
        printf '<pre>\n'
        printf '%s\n' "${_issues}" | _colorize_pre
        printf '</pre>\n\n'
    fi

    printf '## 3. Partition Analysis\n\n'

    if [[ -n "${_chart_sections}" && -f "partition_splits.log" ]]; then
        printf '### Growth Trends\n\n<pre>\n'
        {
            local _sec
            for _sec in yearly quarterly monthly; do
                [[ ",${_chart_sections}," == *",${_sec},"* ]] || continue
                case "${_sec}" in
                    yearly)    _extract_chart_section "--- Yearly Partition Growth ---"    partition_splits.log ;;
                    quarterly) _extract_chart_section "--- Quarterly Partition Growth ---" partition_splits.log ;;
                    monthly)   _extract_chart_section "--- Monthly Partition Growth ---"   partition_splits.log ;;
                esac
                printf '\n'
            done
        } | _colorize_pre
        printf '</pre>\n\n'
    fi

    if [[ -f "partition_growth_plot.log" ]]; then
        printf '### Growth Plots\n\n<pre>\n'
        _colorize_pre < "partition_growth_plot.log"
        printf '</pre>\n\n'
    fi

    local _part="health_report_partition_details.log"
    if [[ -f "${_part}" ]]; then
        printf '### Density Details\n\n<pre>\n'
        {
            echo "Nodes >= 900 Partitions:"
            grep -E "^[[:space:]]*[0-9]+ [0-9.]+[[:space:]]*\[(WARNING|DANGER|CRITICAL)\]" \
                "${_part}" 2>/dev/null | awk '$1 >= 900' | sed 's/^[[:space:]]*//' \
                || echo "None"
        } | _colorize_pre
        printf '</pre>\n'
    fi

    if [[ -n "${_forecast_thresh_new}" ]]; then
        local _fc_out
        _fc_out=$(_run_forecast "${_forecast_thresh_new}")
        if [[ -n "${_fc_out}" ]]; then
            printf '\n### Cluster Growth Forecast\n\n<pre>\n'
            printf '%s\n' "${_fc_out}" | _colorize_pre
            printf '</pre>\n'
        fi
    fi
}

# ── Report body: HTML (for PDF) ───────────────────────────────────────────────

_build_html() {
    local _serial _cluster _version _nodes _memory _mdgw _s3gw _dls
    _serial=$(_find_serial); _cluster=$(_find_cluster_name)
    _version=$(_parse_cs_version); _nodes=$(_parse_node_count)
    _memory=$(_build_memory_summary)
    _mdgw=$(_parse_service_count "MDGW"); _s3gw=$(_parse_service_count "S3GW")
    _dls=$(_parse_service_count "DLS")

    local _hw_data _hw_line="" _hw_rows=""
    _hw_data=$(_parse_lshw_hardware)
    if [[ -n "${_hw_data}" ]]; then
        local _up _ub
        _up=$(printf '%s\n' "${_hw_data}" | cut -f2 | sort -u | wc -l)
        _ub=$(printf '%s\n' "${_hw_data}" | cut -f4 | sort -u | wc -l)
        if [[ "${_up}" -eq 1 && "${_ub}" -eq 1 ]]; then
            local _prod _bios
            _prod=$(printf '%s\n' "${_hw_data}" | cut -f2 | head -n 1)
            _bios=$(printf '%s\n' "${_hw_data}" | cut -f4 | head -n 1)
            _hw_line="All ${_nodes} nodes: ${_prod} | BIOS ${_bios}"
        else
            _hw_rows=$(printf '%s\n' "${_hw_data}" | \
                awk -F'\t' '{ printf "<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n",
                    $1, $3, $2, $4 }')
        fi
    fi

    local _issues _n_crit _n_err _n_warn _n_act _n_total
    _issues=$(_collect_issues)
    _n_crit=$(_count_severity "${_issues}" "CRITICAL|ALERT")
    _n_err=$(_count_severity  "${_issues}" "ERROR")
    _n_warn=$(_count_severity "${_issues}" "WARNING")
    _n_act=$(_count_severity  "${_issues}" "ACTION")
    _n_total=$(( _n_crit + _n_err + _n_warn + _n_act ))

    # ── output ────────────────────────────────────────────────────────────────
    printf '<h1>HCP-CS Health Check Report</h1>\n'
    printf '<p>Generated: %s</p><hr>\n' "$(date)"

    printf '<h2>1. HCP-CS Cluster Identity</h2>\n'
    printf '<table>\n'
    printf '<tr><th>Cluster Serial</th><td>%s</td></tr>\n'    "${_serial}"
    printf '<tr><th>Cluster Name</th><td>%s</td></tr>\n'      "${_cluster}"
    printf '<tr><th>CS Version</th><td>%s</td></tr>\n'        "${_version}"
    printf '<tr><th>Total Nodes</th><td>%s</td></tr>\n'       "${_nodes}"
    printf '<tr><th>Memory</th><td>%s</td></tr>\n'            "${_memory}"
    printf '<tr><th>MDGW / S3GW / DLS</th><td>%s / %s / %s</td></tr>\n' \
        "${_mdgw}" "${_s3gw}" "${_dls}"
    printf '</table>\n'

    if [[ -n "${_hw_line}" ]]; then
        printf '<p><strong>Hardware:</strong> %s</p>\n' "${_hw_line}"
    elif [[ -n "${_hw_rows}" ]]; then
        printf '<p><strong>Hardware (mixed):</strong></p>\n'
        printf '<table>\n<tr><th>Node</th><th>Serial</th><th>Product</th><th>BIOS</th></tr>\n'
        printf '%s\n' "${_hw_rows}"
        printf '</table>\n'
    fi

    printf '<h2>2. Issues by Criticality</h2>\n'
    printf '<table>\n<tr><th>Severity</th><th>Count</th></tr>\n'
    printf '<tr><td><span style="color:#ff4444;font-weight:bold">CRITICAL / ALERT</span></td><td>%s</td></tr>\n' "${_n_crit}"
    printf '<tr><td><span style="color:#ff6666;font-weight:bold">ERROR</span></td><td>%s</td></tr>\n'            "${_n_err}"
    printf '<tr><td><span style="color:#ffcc00;font-weight:bold">WARNING</span></td><td>%s</td></tr>\n'          "${_n_warn}"
    printf '<tr><td>ACTION</td><td>%s</td></tr>\n'                                                               "${_n_act}"
    printf '<tr><td><strong>Total</strong></td><td><strong>%s</strong></td></tr>\n' "${_n_total}"
    printf '</table>\n'

    if [[ "${_n_total}" -eq 0 ]]; then
        printf '<p class="ok">No significant issues detected.</p>\n'
    else
        printf '<pre>\n'
        printf '%s\n' "${_issues}" | _colorize_pre
        printf '</pre>\n'
    fi

    printf '<h2>3. Partition Analysis</h2>\n'

    if [[ -n "${_chart_sections}" && -f "partition_splits.log" ]]; then
        printf '<h3>Growth Trends</h3>\n<pre>\n'
        {
            local _sec
            for _sec in yearly quarterly monthly; do
                [[ ",${_chart_sections}," == *",${_sec},"* ]] || continue
                case "${_sec}" in
                    yearly)    _extract_chart_section "--- Yearly Partition Growth ---"    partition_splits.log ;;
                    quarterly) _extract_chart_section "--- Quarterly Partition Growth ---" partition_splits.log ;;
                    monthly)   _extract_chart_section "--- Monthly Partition Growth ---"   partition_splits.log ;;
                esac
                printf '\n'
            done
        } | _colorize_pre
        printf '</pre>\n'
    fi

    if [[ -f "partition_growth_plot.log" ]]; then
        printf '<h3>Growth Plots</h3>\n<pre>\n'
        _colorize_pre < "partition_growth_plot.log"
        printf '</pre>\n'
    fi

    local _part="health_report_partition_details.log"
    if [[ -f "${_part}" ]]; then
        printf '<h3>Density Details</h3>\n<pre>\n'
        {
            echo "Nodes >= 900 Partitions:"
            grep -E "^[[:space:]]*[0-9]+ [0-9.]+[[:space:]]*\[(WARNING|DANGER|CRITICAL)\]" \
                "${_part}" 2>/dev/null | awk '$1 >= 900' | sed 's/^[[:space:]]*//' \
                || echo "None"
        } | _colorize_pre
        printf '</pre>\n'
    fi

    if [[ -n "${_forecast_thresh_new}" ]]; then
        local _fc_out
        _fc_out=$(_run_forecast "${_forecast_thresh_new}")
        if [[ -n "${_fc_out}" ]]; then
            printf '<h3>Cluster Growth Forecast</h3>\n<pre>\n'
            printf '%s\n' "${_fc_out}" | _colorize_pre
            printf '</pre>\n'
        fi
    fi
}

# ── Output dispatch ───────────────────────────────────────────────────────────

_rpt_tmp=""
_rpt_cleanup() { [[ -z "${_rpt_tmp}" ]] || rm -f "${_rpt_tmp}"; : ; }
trap _rpt_cleanup EXIT

if [[ "${_format}" == "md" ]]; then
    _build_md > "${_out_file}"
    gsc_log_ok "Markdown report: ${_out_file}"

elif [[ "${_format}" == "pdf" ]]; then
    _rpt_tmp=$(mktemp /tmp/gsc_report_XXXXXX.html)
    { _html_head; _build_html; _html_foot; } > "${_rpt_tmp}"

    if _to_pdf "${_rpt_tmp}" "${_out_file}"; then
        gsc_log_ok "PDF report: ${_out_file}"
    else
        _rpt_html="${_out_file%.pdf}.html"
        cp "${_rpt_tmp}" "${_rpt_html}"
        gsc_log_warn "PDF tool unavailable; HTML written to: ${_rpt_html}"
    fi
fi
