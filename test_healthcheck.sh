#!/usr/bin/env bash
#
# test_healthcheck.sh — Automated integration test for gsc_healthcheck.sh
#
# Usage:
#   sudo bash test_healthcheck.sh [-d DIR] [SR1 SR2 ...]
#   -d DIR   CI data directory (default: /ci if it exists, else /opt/ci)
#
# Process:
#   1. Rsync repo to local bin dir
#   2. Scan DIR for 8-digit SR directories
#   3. Clean up stale timestamped run dirs (2025*/2026*)
#   4. Find supportLog bundle in each SR dir
#   5. Run gsc_healthcheck.sh, time each execution
#   6. Report pass/fail summary
#

set -uo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
_REPO_DIR="/home/dablake/src/Process-Health-Check"
_BIN_DIR="/home/dablake/.local/bin"
_TMPDIR="/var/ci/tmp"
_CUSTOMER_NAMES=("HV" "ACME" "THOR" "ODEN" "LOKI")

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
_log() { printf '%s\n' "$*" | tee -a "${_LOG_FILE}"; }
_info()  { printf "${_C_INFO}[INFO ]${_C_RESET} %s\n" "$*" | tee -a "${_LOG_FILE}"; }
_ok()    { printf "${_C_OK}[PASS ]${_C_RESET} %s\n" "$*" | tee -a "${_LOG_FILE}"; }
_fail()  { printf "${_C_FAIL}[FAIL ]${_C_RESET} %s\n" "$*" | tee -a "${_LOG_FILE}"; }
_warn()  { printf "${_C_WARN}[WARN ]${_C_RESET} %s\n" "$*" | tee -a "${_LOG_FILE}"; }
_skip()  { printf "${_C_WARN}[SKIP ]${_C_RESET} %s\n" "$*" | tee -a "${_LOG_FILE}"; }
_sep()   { _log "$(printf '%.0s-' {1..72})"; }

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
# Step 2 — Find supportLog bundle for an SR dir
#   Prefers bare supportLogs_*.tar.xz over node-prefixed variants.
#   Returns the first match via stdout.
# ---------------------------------------------------------------------------
_find_bundle() {
    local _sr_dir="$1"

    # Prefer the canonical supportLogs_*.tar.xz (no node prefix)
    local _f
    _f=$(find "${_sr_dir}" -maxdepth 1 \
        \( -name "supportLogs_*.tar.xz" -o -name "supportLogs_*.tar.*.xz" \) \
        ! -name "*-*-supportLogs_*" \
        -print -quit 2>/dev/null)
    [[ -n "${_f}" ]] && echo "${_f}" && return

    # Fallback: any file with supportLog in the name (xz archives only)
    _f=$(find "${_sr_dir}" -maxdepth 1 \
        -name "*supportLog*" \
        \( -name "*.xz" -o -name "*.tar.xz" \) \
        -print -quit 2>/dev/null)
    [[ -n "${_f}" ]] && echo "${_f}" && return

    echo ""
}

# ---------------------------------------------------------------------------
# Step 3 — Remove stale timestamped run directories
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
# Option parsing — -d DIR sets CI data dir; remaining args are SR filters
# e.g.: sudo bash test_healthcheck.sh -d /opt/ci 05455380 05448336
# ---------------------------------------------------------------------------
_CI_DIR=""
declare -a _sr_filter=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d)      _CI_DIR="$2"; shift 2 ;;
        -d*)     _CI_DIR="${1#-d}"; shift ;;
        --dir=*) _CI_DIR="${1#--dir=}"; shift ;;
        --dir)   _CI_DIR="$2"; shift 2 ;;
        *)       _sr_filter+=("$1"); shift ;;
    esac
done
if [[ -z "${_CI_DIR}" ]]; then
    if [[ -d "/ci" ]]; then _CI_DIR="/ci"; else _CI_DIR="/opt/ci"; fi
fi
_LOG_FILE="${_CI_DIR}/test_healthcheck_$(date +%Y%m%d_%H%M%S).log"

# ---------------------------------------------------------------------------
mkdir -p "$(dirname "${_LOG_FILE}")"
mkdir -p "${_TMPDIR}"
export TMPDIR="${_TMPDIR}"
: > "${_LOG_FILE}"

_log ""
_log "$(printf "${_C_BOLD}%s${_C_RESET}" "HCP Cloud Scale — gsc_healthcheck.sh Automated Test")"
_log "Started : $(date)"
_log "Log     : ${_LOG_FILE}"
_sep

# Step 1: deploy
_deploy
_sep

# Counters
_total=0
_passed=0
_failed=0
_skipped=0
_idx=0
_overall_start=$(date +%s)

# Collect results for final table
declare -a _results=()

# Step 2: iterate SR dirs
for _sr_path in "${_CI_DIR}"/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]; do
    [[ -d "${_sr_path}" ]] || continue
    _sr=$(basename "${_sr_path}")

    # If SR filter specified, skip non-matching SRs
    if [[ ${#_sr_filter[@]} -gt 0 ]]; then
        _match=0
        for _f in "${_sr_filter[@]}"; do [[ "${_sr}" == "${_f}" ]] && _match=1 && break; done
        [[ ${_match} -eq 0 ]] && continue
    fi

    # Pick customer name (cycle deterministically)
    _customer="${_CUSTOMER_NAMES[$((_idx % ${#_CUSTOMER_NAMES[@]}))]}"
    ((_idx++)) || true

    _log ""
    _info "SR=${_sr}  Customer=${_customer}"

    # Step 3: clean stale run dirs
    _clean_stale "${_sr_path}"

    # Step 4: find bundle
    _bundle=$(_find_bundle "${_sr_path}")
    if [[ -z "${_bundle}" ]]; then
        _skip "${_sr}: no supportLog bundle found"
        ((_skipped++)) || true
        _results+=("SKIP  | ${_sr} | ${_customer} | no bundle | -")
        continue
    fi

    _info "  Bundle : $(basename "${_bundle}")"
    ((_total++)) || true

    # Step 5: run gsc_healthcheck.sh, timed
    _t_start=$(date +%s)
    _sr_log="${_sr_path}/test_run_$(date +%Y%m%d_%H%M%S).log"

    (
        cd "${_sr_path}" || exit 1
        sudo TMPDIR="${_TMPDIR}" "${_BIN_DIR}/gsc_healthcheck.sh" \
            -c "${_customer}" \
            -s "${_sr}" \
            -f "${_bundle}"
    ) >> "${_sr_log}" 2>&1
    _rc=$?

    _t_end=$(date +%s)
    _t_elapsed=$(( _t_end - _t_start ))
    _t_fmt=$(_elapsed_fmt "${_t_elapsed}")

    if [[ ${_rc} -eq 0 ]]; then
        _ok  "${_sr}: PASS  (${_t_fmt})"
        ((_passed++)) || true
        _results+=("PASS  | ${_sr} | ${_customer} | $(basename "${_bundle}") | ${_t_fmt}")
    else
        _fail "${_sr}: FAIL  (exit ${_rc})  (${_t_fmt})  — see ${_sr_log}"
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
    _f1=$(echo "${_r}" | awk -F' *\\| *' '{print $1}')
    _f2=$(echo "${_r}" | awk -F' *\\| *' '{print $2}')
    _f3=$(echo "${_r}" | awk -F' *\\| *' '{print $3}')
    _f4=$(echo "${_r}" | awk -F' *\\| *' '{print $4}')
    _f5=$(echo "${_r}" | awk -F' *\\| *' '{print $5}')
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
