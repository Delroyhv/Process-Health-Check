#!/usr/bin/env bash
#
# test_battery.sh — Full sequence battery test: expand → prometheus → runchk
#
# Test sequence per SR:
#   1. Deploy repo to local bin dir
#   2. Global Prometheus cleanup (--cleanup --override=y)
#   3. For each SR directory:
#      A. expand_hcpcs_support.sh -f <bundle>
#      B. cd into the created run dir
#      C. Find psnap_*.tar.xz
#      D. If psnap: gsc_prometheus.sh -f <psnap> -c <customer> -s <SR> -b .
#         If no psnap: note --no-metrics for runchk
#      E. runchk.sh -f healthcheck.conf [--no-metrics]
#      F. runchk.sh -f healthcheck.conf [--no-metrics] --report <customer>.md
#   4. Summary table
#
# Usage:
#   sudo bash test_battery.sh [SR1 SR2 ...]
#   # No args = run all SRs under /ci
#

set -uo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
_REPO_DIR="/home/dablake/src/Process-Health-Check"
_BIN_DIR="/home/dablake/.local/bin"
_CI_DIR="/ci"
_TMPDIR="/var/ci/tmp"
_CUSTOMER_NAMES=("HV" "ACME" "THOR" "ODEN" "LOKI")
_LOG_FILE="${_CI_DIR}/test_battery_$(date +%Y%m%d_%H%M%S).log"

# Colours
_C_OK="\033[32m"
_C_FAIL="\033[31m"
_C_WARN="\033[33m"
_C_INFO="\033[36m"
_C_BOLD="\033[1m"
_C_RESET="\033[0m"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
_log()  { printf '%s\n' "$*" | tee -a "${_LOG_FILE}"; }
_info() { printf "${_C_INFO}[INFO ]${_C_RESET} %s\n" "$*" | tee -a "${_LOG_FILE}"; }
_ok()   { printf "${_C_OK}[PASS ]${_C_RESET} %s\n" "$*" | tee -a "${_LOG_FILE}"; }
_fail() { printf "${_C_FAIL}[FAIL ]${_C_RESET} %s\n" "$*" | tee -a "${_LOG_FILE}"; }
_warn() { printf "${_C_WARN}[WARN ]${_C_RESET} %s\n" "$*" | tee -a "${_LOG_FILE}"; }
_skip() { printf "${_C_WARN}[SKIP ]${_C_RESET} %s\n" "$*" | tee -a "${_LOG_FILE}"; }
_sep()  { _log "$(printf '%.0s-' {1..72})"; }

_elapsed_fmt() {
    local s=$1
    printf '%dm %02ds' $(( s / 60 )) $(( s % 60 ))
}

# ---------------------------------------------------------------------------
# Step 1 — Deploy repo to local bin dir
# ---------------------------------------------------------------------------
_deploy() {
    _info "Deploying ${_REPO_DIR}/ → ${_BIN_DIR}/"
    if rsync -av --exclude=".git" --exclude="*.tar.xz" --exclude="*.sha256" \
        "${_REPO_DIR}/" "${_BIN_DIR}/" >> "${_LOG_FILE}" 2>&1; then
        _ok "Deploy complete"
    else
        _fail "rsync failed — aborting"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Find supportLog bundle in an SR dir
# ---------------------------------------------------------------------------
_find_bundle() {
    local _sr_dir="$1"
    local _f
    _f=$(find "${_sr_dir}" -maxdepth 1 \
        \( -name "supportLogs_*.tar.xz" -o -name "supportLogs_*.tar.*.xz" \) \
        ! -name "*-*-supportLogs_*" \
        -print -quit 2>/dev/null)
    [[ -n "${_f}" ]] && echo "${_f}" && return

    _f=$(find "${_sr_dir}" -maxdepth 1 \
        -name "*supportLog*" \
        \( -name "*.xz" -o -name "*.tar.xz" \) \
        -print -quit 2>/dev/null)
    [[ -n "${_f}" ]] && echo "${_f}" && return

    echo ""
}

# ---------------------------------------------------------------------------
# Remove stale timestamped run dirs
# ---------------------------------------------------------------------------
_clean_stale() {
    local _sr_dir="$1"
    local _removed=0
    for _d in "${_sr_dir}"/2025* "${_sr_dir}"/2026*; do
        if [[ -d "${_d}" ]]; then
            _warn "  Removing stale run dir: ${_d}"
            rm -rf "${_d}"
            ((_removed++)) || true
        fi
    done
    [[ ${_removed} -gt 0 ]] && _info "  Cleaned ${_removed} stale dir(s)"
}

# ---------------------------------------------------------------------------
# Optional SR filter: pass SR numbers as arguments to limit which SRs are tested
# e.g.: sudo bash test_battery.sh 05455380 05448336
declare -a _sr_filter=("$@")

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "${_LOG_FILE}")"
mkdir -p "${_TMPDIR}"
export TMPDIR="${_TMPDIR}"
: > "${_LOG_FILE}"

_log ""
_log "$(printf "${_C_BOLD}%s${_C_RESET}" "HCP Cloud Scale — Battery Integration Test")"
_log "Started : $(date)"
_log "Log     : ${_LOG_FILE}"
_sep

# Step 1: deploy
_deploy
_sep

# Step 2: global Prometheus cleanup
_info "Global Prometheus cleanup (--cleanup --override=y)..."
sudo TMPDIR="${_TMPDIR}" "${_BIN_DIR}/gsc_prometheus.sh" \
    --cleanup --override=y 2>&1 | tee -a "${_LOG_FILE}" || true
_ok "Prometheus cleanup complete"
_sep

# Counters
_total=0
_passed=0
_failed=0
_skipped=0
_idx=0
_overall_start=$(date +%s)

declare -a _results=()

# ---------------------------------------------------------------------------
# Step 3 — Iterate SR dirs
# ---------------------------------------------------------------------------
for _sr_path in "${_CI_DIR}"/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]; do
    [[ -d "${_sr_path}" ]] || continue
    _sr=$(basename "${_sr_path}")

    # SR filter
    if [[ ${#_sr_filter[@]} -gt 0 ]]; then
        _match=0
        for _f in "${_sr_filter[@]}"; do [[ "${_sr}" == "${_f}" ]] && _match=1 && break; done
        [[ ${_match} -eq 0 ]] && continue
    fi

    _customer="${_CUSTOMER_NAMES[$((_idx % ${#_CUSTOMER_NAMES[@]}))]}"
    ((_idx++)) || true

    _log ""
    _info "SR=${_sr}  Customer=${_customer}"

    _clean_stale "${_sr_path}"

    _bundle=$(_find_bundle "${_sr_path}")
    if [[ -z "${_bundle}" ]]; then
        _skip "${_sr}: no supportLog bundle found"
        ((_skipped++)) || true
        _results+=("SKIP  | ${_sr} | ${_customer} | no bundle | -")
        continue
    fi

    _info "  Bundle : $(basename "${_bundle}")"
    ((_total++)) || true

    _t_start=$(date +%s)
    _sr_log="${_sr_path}/run_battery_$(date +%Y%m%d_%H%M%S).log"
    : > "${_sr_log}"

    # ── Step A: Expand support bundle ────────────────────────────────────────
    _info "  Step A: Expanding support bundle..."
    sudo TMPDIR="${_TMPDIR}" "${_BIN_DIR}/expand_hcpcs_support.sh" \
        -f "${_bundle}" 2>&1 | tee -a "${_sr_log}" || true

    # Find the run dir created by expand
    _run_dir=""
    _run_dir=$(grep "Healthcheck config created:" "${_sr_log}" \
        | sed 's/.*: //' | xargs -r dirname | head -n 1 || true)
    [[ -z "${_run_dir}" ]] && \
        _run_dir=$(grep "Support Log extracted:" "${_sr_log}" \
            | sed 's/.*: //' | head -n 1 || true)
    [[ -z "${_run_dir}" ]] && \
        _run_dir=$(find "${_sr_path}" -maxdepth 1 -type d \
            -name "20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]_*" 2>/dev/null \
            | sort -r | head -n 1 || true)

    if [[ -z "${_run_dir}" || ! -d "${_run_dir}" ]]; then
        _t_end=$(date +%s)
        _t_fmt=$(_elapsed_fmt $(( _t_end - _t_start )))
        _fail "${_sr}: Step A FAIL — run dir not found after expand — see ${_sr_log}"
        ((_failed++)) || true
        _results+=("FAIL  | ${_sr} | ${_customer} | $(basename "${_bundle}") | ${_t_fmt}")
        continue
    fi

    _info "  Run dir: ${_run_dir}"

    # ── Steps B–F: run inside the created run dir ─────────────────────────────
    (
        cd "${_run_dir}" || exit 1

        # Step B: Find psnap
        _psnap=$(find . -maxdepth 1 -name "psnap_*.tar.xz" -print -quit 2>/dev/null || true)

        if [[ -n "${_psnap}" ]]; then
            # Step C: Start Prometheus with psnap
            printf '[INFO] Step C: Starting Prometheus — psnap: %s\n' "${_psnap}"
            sudo TMPDIR="${_TMPDIR}" "${_BIN_DIR}/gsc_prometheus.sh" \
                -f "${_psnap}" -c "${_customer}" -s "${_sr}" -b . || true

            # Step D: runchk with metrics
            printf '[INFO] Step D: Running runchk.sh -f healthcheck.conf\n'
            sudo TMPDIR="${_TMPDIR}" "${_BIN_DIR}/runchk.sh" \
                -f healthcheck.conf || true

            # Step E: runchk with report
            printf '[INFO] Step E: Running runchk.sh --report %s_report.md\n' "${_customer}"
            sudo TMPDIR="${_TMPDIR}" "${_BIN_DIR}/runchk.sh" \
                -f healthcheck.conf \
                --report "${_customer}_report.md" || true
        else
            # Step C: No psnap — use --no-metrics
            printf '[WARN] Step C: No psnap found — using --no-metrics\n'

            # Step D: runchk --no-metrics
            printf '[INFO] Step D: Running runchk.sh --no-metrics -f healthcheck.conf\n'
            sudo TMPDIR="${_TMPDIR}" "${_BIN_DIR}/runchk.sh" \
                --no-metrics -f healthcheck.conf || true

            # Step E: runchk --no-metrics with report
            printf '[INFO] Step E: Running runchk.sh --no-metrics --report %s_report.md\n' "${_customer}"
            sudo TMPDIR="${_TMPDIR}" "${_BIN_DIR}/runchk.sh" \
                --no-metrics -f healthcheck.conf \
                --report "${_customer}_report.md" || true
        fi

        printf '[INFO] Battery steps B–E complete.\n'
    ) >> "${_sr_log}" 2>&1
    _step_rc=$?

    _t_end=$(date +%s)
    _t_elapsed=$(( _t_end - _t_start ))
    _t_fmt=$(_elapsed_fmt "${_t_elapsed}")

    if [[ ${_step_rc} -eq 0 ]]; then
        _ok  "${_sr}: PASS  (${_t_fmt})"
        ((_passed++)) || true
        _results+=("PASS  | ${_sr} | ${_customer} | $(basename "${_bundle}") | ${_t_fmt}")
    else
        _fail "${_sr}: FAIL  (exit ${_step_rc})  (${_t_fmt})  — see ${_sr_log}"
        ((_failed++)) || true
        _results+=("FAIL  | ${_sr} | ${_customer} | $(basename "${_bundle}") | ${_t_fmt}")
    fi
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
_overall_end=$(date +%s)
_overall_elapsed=$(( _overall_end - _overall_start ))

_sep
_log ""
_log "$(printf '%sSUMMARY%s' "${_C_BOLD}" "${_C_RESET}")"
_log "Finished : $(date)"
_log "Elapsed  : $(_elapsed_fmt "${_overall_elapsed}")"
_log ""
printf "%-6s | %-10s | %-8s | %-45s | %s\n" \
    "Result" "SR" "Customer" "Bundle" "Time" | tee -a "${_LOG_FILE}"
printf '%.0s-' {1..90} | tee -a "${_LOG_FILE}"; printf '\n' | tee -a "${_LOG_FILE}"
for _r in "${_results[@]}"; do
    _f1=$(printf '%s' "${_r}" | awk -F' *\\| *' '{print $1}')
    _f2=$(printf '%s' "${_r}" | awk -F' *\\| *' '{print $2}')
    _f3=$(printf '%s' "${_r}" | awk -F' *\\| *' '{print $3}')
    _f4=$(printf '%s' "${_r}" | awk -F' *\\| *' '{print $4}')
    _f5=$(printf '%s' "${_r}" | awk -F' *\\| *' '{print $5}')
    printf "%-6s | %-10s | %-8s | %-45s | %s\n" \
        "${_f1}" "${_f2}" "${_f3}" "${_f4}" "${_f5}" | tee -a "${_LOG_FILE}"
done
_sep
_log ""
_log "Total SRs tested : ${_total}"
printf "${_C_OK}Passed${_C_RESET}           : %s\n" "${_passed}" | tee -a "${_LOG_FILE}"
printf "${_C_FAIL}Failed${_C_RESET}           : %s\n" "${_failed}" | tee -a "${_LOG_FILE}"
printf "${_C_WARN}Skipped${_C_RESET}          : %s\n" "${_skipped}" | tee -a "${_LOG_FILE}"
_log ""
_log "Full log : ${_LOG_FILE}"
_log ""

[[ ${_failed} -eq 0 ]]
