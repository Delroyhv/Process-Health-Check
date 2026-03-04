#!/usr/bin/env bash
#
# gsc_healthcheck.sh - End-to-end wrapper for HCP-CS health checks
#
# Usage: ./gsc_healthcheck.sh -c <customer> -s <sr_number> [options]
#

set -euo pipefail
IFS=$'\n\t'

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load core library
if [[ -r "${_script_dir}/gsc_core.sh" ]]; then
  # shellcheck disable=SC1091
  . "${_script_dir}/gsc_core.sh"
else
  echo "ERROR: gsc_core.sh not found in ${_script_dir}" >&2
  exit 1
fi

# Recommended trap for cleanup and memory wiping
trap gsc_cleanup EXIT

_customer=""
_sr_number=""
_support_log=""
_no_metrics=0
_no_psnap=0
_cleanup_mode=0
_override_confirm=""

usage() {
  cat <<EOF
Usage: $(basename "$0") -c <customer> -s <sr_number> [options]

Mandatory:
  -c, --customer NAME      Customer name
  -s, --sr SR_NUMBER       Service Request number

Options:
  -f, --file PATH          Path to supportLogs_*.tar.xz bundle
  --no-psnap               Skip Prometheus snapshot expansion/startup
  --no-metrics             Run health check without Prometheus metrics
  --cleanup                Cleanup containers and REMOVE the extraction directory
  --override=y             Skip confirmation for cleanup
  -h, --help               Show this help message

Example:
  sudo ./gsc_healthcheck.sh -c ACME -s 01234567 -f supportLogs_2026-01-01.tar.xz
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -c|--customer) _customer="$2"; shift 2 ;;
      -s|--sr) _sr_number="$2"; shift 2 ;;
      -f|--file) _support_log="$2"; shift 2 ;;
      --no-psnap) _no_psnap=1; _no_metrics=1; shift ;;
      --no-metrics) _no_metrics=1; shift ;;
      --cleanup) _cleanup_mode=1; shift ;;
      --override=y) _override_confirm="y"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) gsc_log_error "Unknown argument: $1"; usage; exit 1 ;;
    esac
  done
  [[ -n "${_customer}" ]] || gsc_die "Customer name (-c) is mandatory."
  [[ -n "${_sr_number}" ]] || gsc_die "SR number (-s) is mandatory."
}

do_cleanup() {
  gsc_log_info "Cleaning up health check artifacts for ${_customer} / ${_sr_number}..."
  
  # Ensure we have sudo access for cleanup
  gsc_prompt_sudo_password

  # 1. Stop Prometheus containers matching this SR/customer
  local _runtime
  _runtime=$(gsc_detect_engine)
  # Pattern matches gsc_prometheus_CUSTOMER_SR_PORT
  gsc_container_cleanup "${_runtime}" "^gsc_prometheus_${_customer}_${_sr_number}_" "${_override_confirm}" "0"

  # 2. Locate and remove the directory
  local _target_dir=""
  local _sr_base_dir=""
  if [[ -d "${_sr_number}" ]]; then
    _sr_base_dir="${_sr_number}"
  elif [[ -d "/ci/${_sr_number}" ]]; then
    _sr_base_dir="/ci/${_sr_number}"
  fi

  if [[ -n "${_sr_base_dir}" ]]; then
    _target_dir=$(find "${_sr_base_dir}" -maxdepth 1 -type d -name "20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]_*" | sort -r | head -n 1)
  fi

  if [[ -n "${_target_dir}" && -d "${_target_dir}" ]]; then
    if [[ "${_override_confirm}" != "y" ]]; then
        read -p "REALLY remove directory ${_target_dir}? (y/N): " _ans
        [[ "${_ans,,}" != "y" ]] && gsc_die "Directory removal cancelled."
    fi
    gsc_log_info "Removing directory (with gsc_sudo): ${_target_dir}"
    gsc_sudo rm -rf "${_target_dir}"
    gsc_log_success "Cleanup complete."
  else
    gsc_log_warn "Could not find extraction directory to remove."
  fi
}

main() {
  parse_args "$@"

  if [[ "${_cleanup_mode}" -eq 1 ]]; then
    do_cleanup
    exit 0
  fi

  # Prompt for sudo password once at the start if needed
  gsc_prompt_sudo_password

  gsc_log_info "Step 1: Expanding support bundle..."
  local _expand_cmd=("${_script_dir}/expand_hcpcs_support.sh")
  [[ -n "${_support_log}" ]] && _expand_cmd+=("-f" "${_support_log}")
  
  local _tmp_out
  _tmp_out=$(mktemp)
  gsc_add_tmp_dir "$(dirname "${_tmp_out}")" # will be cleaned up by gsc_cleanup

  ( "${_expand_cmd[@]}" ) 2>&1 | tee "${_tmp_out}" || gsc_log_info "Expansion step finished."

  gsc_log_info "Step 2: Locating health check directory for SR ${_sr_number}..."
  local _target_dir=""
  
  _target_dir=$(grep "Healthcheck config created:" "${_tmp_out}" | sed 's/.*: //' | xargs -r dirname | head -n 1 || echo "")
  [[ -z "${_target_dir}" ]] && _target_dir=$(grep "Support Log extracted:" "${_tmp_out}" | sed 's/.*: //' | head -n 1 || echo "")
  [[ -z "${_target_dir}" ]] && _target_dir=$(grep "Moved psnap into SupportLog directory:" "${_tmp_out}" | sed 's/.*: //' | xargs -r dirname | head -n 1 || echo "")

  if [[ -z "${_target_dir}" ]]; then
    local _sr_base_dir=""
    if [[ -d "${_sr_number}" ]]; then
      _sr_base_dir="${_sr_number}"
    elif [[ -d "/ci/${_sr_number}" ]]; then
      _sr_base_dir="/ci/${_sr_number}"
    else
      _sr_base_dir="."
    fi
    _target_dir=$(find "${_sr_base_dir}" -maxdepth 2 -type d -name "20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]_*" | sort -r | head -n 1 || echo "")
  fi

  [[ -n "${_target_dir}" && -d "${_target_dir}" ]] || gsc_die "Could not find health check directory for SR ${_sr_number}."

  gsc_log_info "Step 3: Entering directory: ${_target_dir}"
  cd "${_target_dir}"

  # Step 4: Prometheus Setup
  local _snapshot
  _snapshot=$(ls psnap_*.tar.xz 2>/dev/null | head -n 1 || echo "")

  if [[ "${_no_psnap}" -eq 0 && "${_no_metrics}" -eq 0 && -n "${_snapshot}" ]]; then
    gsc_log_info "Step 4: Running gsc_prometheus.sh with gsc_sudo for snapshot: ${_snapshot}"
    gsc_sudo "${_script_dir}/gsc_prometheus.sh" -c "${_customer}" -s "${_sr_number}" -f "${_snapshot}" -b .
  elif [[ "${_no_psnap}" -eq 1 || "${_no_metrics}" -eq 1 ]]; then
    gsc_log_info "Step 4: Skipping Prometheus setup (--no-psnap or --no-metrics set)."
  elif [[ "${_no_metrics}" -eq 0 ]]; then
    if [[ -f "healthcheck.conf" ]]; then
      gsc_log_info "Step 4: Prometheus already set up (healthcheck.conf exists)."
    else
      gsc_log_warn "Step 4: No snapshot found and no healthcheck.conf; disabling metrics."
      _no_metrics=1
    fi
  fi

  # Step 5: Run Health Check
  gsc_log_info "Step 5: Running health check suite..."
  local _chk_args=()
  [[ -f "healthcheck.conf" ]] && _chk_args+=("-f" "healthcheck.conf")
  [[ "${_no_metrics}" -eq 1 ]] && _chk_args+=("--no-metrics")

  "${_script_dir}/runchk.sh" "${_chk_args[@]}"

  gsc_log_success "Health check complete for ${_customer} / ${_sr_number}."
}

main "$@"
