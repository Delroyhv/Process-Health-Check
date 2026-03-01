#!/usr/bin/env bash
#
# ========================================================================
# Copyright (c) by Hitachi Vantara, 2024. All rights reserved.
# ========================================================================
#
# Parse collected journald log files (*journal*.out) from cluster nodes.
#
# Scope: only entries from the last 30 days are considered.
#
# Classification (journald syslog priority levels):
#   ERROR   — priorities 0–3 (emerg, alert, crit, err): deduplicated and
#             summarised per day with occurrence count; written to
#             health_report_messages.log; one brief WARNING line per node
#             printed to screen.
#   WARNING — priority 4 (warning): written to messages_warn.log only
#             (individual lines, not summarised)
#   Lower   — notice/info/debug: silently skipped
#
# ERROR patterns (priorities 0–3):
#   error, failed, failure, BUG: (kernel), panic, oom-kill/oom_kill,
#   emerg, crit:, Call Trace (kernel stack dump), segfault,
#   I/O error, MCE hardware error
#
# WARNING patterns (priority 4):
#   warning/warn:, degraded, deprecated, timeout
#
# Multiple journal files for the same node are consolidated — a single
# summary line per node is printed to screen.
#
# Error deduplication — repeated messages are collapsed per day.
# Before grouping, the message key is normalised:
#   PIDs        process[1234]    → process[N]
#   Hex addrs   0xffff88001234   → 0xN
#   Exit codes  Exited (137)     → Exited (N)
# Within each node the summary is sorted: day ascending, then count
# descending — highest-frequency errors appear first within each day.
# Both short format (Feb 24 10:15:32) and ISO format
# (2024-02-24T10:15:32+0000) timestamps are recognised; short-format
# dates are converted to YYYY-MM-DD for consistent output and filtering.
# Year is inferred: if the log month exceeds the current month the entry
# is assumed to be from the previous calendar year.
#
# References:
#   journalctl(1) — systemd journal query tool
#     https://www.man7.org/linux/man-pages/man1/journalctl.1.html
#     Priority levels: 0=emerg 1=alert 2=crit 3=err 4=warning 5=notice
#                      6=info  7=debug
#     Useful options: -p err (errors and above), -p warning,
#                     --since "24 hours ago", --no-pager, -n N
#   Red Hat Enterprise Linux 8 — Viewing and Managing Log Files
#     https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/
#     8/html/configuring_basic_system_settings/
#     assembly_viewing-and-managing-log-files_configuring-basic-system-settings
#   Red Hat Knowledgebase — Using journalctl to view systemd logs (Article 4177861)
#     https://access.redhat.com/articles/4177861
#     Persistent logging: set Storage=persistent in /etc/systemd/journald.conf
#     Filtering by unit: journalctl -u <unit> -p err
#   systemd.journal-fields(7) — well-known journal fields
#     https://www.man7.org/linux/man-pages/man7/systemd.journal-fields.7.html
#

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${_script_dir}/gsc_core.sh"

_default_output_file="health_report_messages.log"
_default_warn_log="messages_warn.log"
_log_dir="."
_output_file="${_default_output_file}"
_warn_log="${_default_warn_log}"
_err=0

usage() {
    local _this_filename
    _this_filename=$(basename "$0")
    echo "\
Parse journal log messages across all cluster nodes.

${_this_filename} [-d <dir>] [-o <output>]

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

gsc_log_info "== CHECKING JOURNAL MESSAGES =="
gsc_rotate_log "${_output_file}"
: > "${_warn_log}"

# 30-day scope — entries older than this YYYY-MM-DD date are ignored
_cutoff=$(date -d "30 days ago" +%Y-%m-%d 2>/dev/null || date -v-30d +%Y-%m-%d)
_cur_year=$(date +%Y)
_cur_month=$(date +%m)   # two-digit; awk treats as integer via +0

mapfile -t _journal_files < <(find "${_log_dir}" -name '*journal*.out' \
    ! -name '*.err' 2>/dev/null | sort)

if [[ "${#_journal_files[@]}" -eq 0 ]]; then
    gsc_loga "WARNING: No journal files found in ${_log_dir}"
    exit 0
fi

gsc_log_info "Found ${#_journal_files[@]} journal file(s) (scope: last 30 days, cutoff ${_cutoff})"

# ── Group files by node ───────────────────────────────────────────────────
# Multiple journal files can exist for the same node (different collection
# windows). Build node → newline-separated file list so all files for a
# node are processed together and produce a single screen summary line.
declare -A _node_to_files
for _file in "${_journal_files[@]}"; do
    _n=$(basename "${_file}" \
        | sed 's/^node_info_//; s/_[0-9]\{4\}-[A-Z][a-z][a-z]-.*//')
    _node_to_files["${_n}"]+="${_file}"$'\n'
done

_total_errors=0
_total_occurrences=0
_total_warns=0
_nodes_with_errors=0

for _node in $(printf '%s\n' "${!_node_to_files[@]}" | sort); do

    mapfile -t _node_files < <(
        printf '%s' "${_node_to_files[${_node}]}" | sort | grep -v '^$'
    )

    _node_errors=0
    _node_occurrences=0
    _node_warns=0

    # ── Pass 1: ERROR summary (all files for this node) ──────────────────
    # Accumulate (day, normalised_message) → count across all files for the
    # node, then emit one TSV line per unique pair in END{}.
    # Sorted: day ascending, count descending (most frequent first per day).
    #
    # Date handling:
    #   ISO format  "2024-02-24T10:15:32+0000 ..."  → YYYY-MM-DD from $1
    #   Short format "Feb 24 10:15:32 hostname ..."  → YYYY-MM-DD inferred
    #     (year = current year; if log month > current month → previous year)
    #
    # Cutoff: entries with day < cutoff (30 days ago) are skipped.
    #
    # Written to log file only — not printed to screen.
    printf '=== %s ===\n' "${_node}" >> "${_output_file}"
    while IFS=$'\t' read -r _day _count _msg; do
        ((_node_errors++))
        ((_node_occurrences += _count))
        ((_err++))
        printf 'ERROR: %-30s  %-12s  %5sx  %s\n' \
            "${_node}" "${_day}" "${_count}" "${_msg}" >> "${_output_file}"
    done < <(awk \
        -v cutoff="${_cutoff}" \
        -v cur_year="${_cur_year}" \
        -v cur_month="${_cur_month}" '
        BEGIN {
            split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", mn)
            for (i = 1; i <= 12; i++) mnum[mn[i]] = i
        }

        /^-- /           { next }
        /^[[:space:]]*$/ { next }

        /[Ee]rror|[Ff]ailed|[Ff]ailure|BUG:|[Pp]anic|oom-kill|oom_kill|[Ee]merg|[Cc]rit:|Call Trace|segfault|I[/]O error|MCE hardware/ {
            if ($1 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/) {
                day = substr($1, 1, 10)              # YYYY-MM-DD
                key = $0; sub(/^[^ ]+ /, "", key)    # strip ISO timestamp
            } else {
                # Short format: Mon DD HH:MM:SS hostname ...
                m = mnum[$1]
                y = (m > cur_month+0) ? cur_year-1 : cur_year+0
                day = sprintf("%04d-%02d-%02d", y, m, $2+0)
                key = $0
                sub(/^[^ ]+ +[^ ]+ +[^ ]+ /, "", key)  # strip Mon DD HH:MM:SS
            }

            if (day < cutoff) next

            gsub(/\[[0-9]+\]/, "[N]",    key)
            gsub(/0x[0-9a-fA-F]+/, "0xN", key)
            gsub(/\([0-9]+\)/, "(N)",    key)

            count[day SUBSEP key]++
            day_of[day SUBSEP key] = day
            msg_of[day SUBSEP key] = key
        }

        END {
            for (k in count)
                printf "%s\t%d\t%s\n", day_of[k], count[k], msg_of[k]
        }
    ' "${_node_files[@]}" | sort -t$'\t' -k1,1 -k2,2rn)

    # ── Pass 2: WARNING lines → warn log (all files for this node) ───────
    # Warnings are written individually (not summarised) as they are less
    # frequent and full context is needed for investigation.
    # Same 30-day cutoff applies.
    printf '=== %s ===\n' "${_node}" >> "${_warn_log}"
    _node_warns=$(awk \
        -v warnlog="${_warn_log}" \
        -v cutoff="${_cutoff}" \
        -v cur_year="${_cur_year}" \
        -v cur_month="${_cur_month}" '
        BEGIN {
            split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", mn)
            for (i = 1; i <= 12; i++) mnum[mn[i]] = i
        }

        /^-- /           { next }
        /^[[:space:]]*$/ { next }
        /[Ee]rror|[Ff]ailed|[Ff]ailure|BUG:|[Pp]anic|oom-kill|oom_kill|[Ee]merg|[Cc]rit:|Call Trace|segfault|I[/]O error|MCE hardware/ { next }

        /[Ww]arning|[Ww]arn:|[Dd]egraded|[Dd]eprecated|[Tt]imeout/ {
            if ($1 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/) {
                day = substr($1, 1, 10)
            } else {
                m = mnum[$1]
                y = (m > cur_month+0) ? cur_year-1 : cur_year+0
                day = sprintf("%04d-%02d-%02d", y, m, $2+0)
            }
            if (day < cutoff) next
            print >> warnlog
            n++
        }

        END { print n+0 }
    ' "${_node_files[@]}")
    printf '\n' >> "${_warn_log}"

    ((_total_errors      += _node_errors))
    ((_total_occurrences += _node_occurrences))
    ((_total_warns       += _node_warns))

    # One brief screen line per node — only when errors found; no filenames
    if [[ "${_node_errors}" -gt 0 ]]; then
        ((_nodes_with_errors++))
        gsc_log_warn "${_node}: ${_node_errors} unique error pattern(s) (${_node_occurrences} total occurrences)"
    fi

    # Per-node summary — log file only
    printf 'INFO: %s: %d unique error pattern(s) (%d total occurrences), %d warning line(s)\n\n' \
        "${_node}" "${_node_errors}" "${_node_occurrences}" "${_node_warns}" >> "${_output_file}"

done

gsc_loga ""
gsc_loga "INFO: Journal scan complete — ${#_node_to_files[@]} node(s) (${#_journal_files[@]} file(s)), ${_nodes_with_errors} with errors (last 30 days)"
gsc_loga "INFO: Total — ${_total_errors} unique error pattern(s), ${_total_occurrences} total occurrences, ${_total_warns} warning line(s)"

if [[ "${_err}" -gt 0 ]]; then
    gsc_loga "Detected ${_err} unique error pattern(s) in journal (${_total_occurrences} total occurrences)"
else
    gsc_loga "INFO: No error-level journal messages found in the last 30 days"
fi
