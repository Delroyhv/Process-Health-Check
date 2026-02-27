#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ----------------------------------------------------------------------------
# selfcheck.sh
# Quick sanity checks before running the bundle.
# Verifies required scripts exist + are executable and key dependencies exist.
# ----------------------------------------------------------------------------

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${_script_dir}/gsc_core.sh"

gsc_log_info "== BUNDLE SELFCHECK =="

# Ensure we are using bundle-local core functions
if [[ ! -r "${_script_dir}/gsc_core.sh" ]]; then
  gsc_die "Missing bundle-local gsc_core.sh in ${_script_dir}"
fi

# Dependencies
gsc_log_info "Checking dependencies..."
gsc_require awk grep sed find jq tee

# Required scripts (add more here if you want to hard-fail)
_required=(
  "runchk.sh"
  "gsc_core.sh"
  "prep_partitions_json.sh"
  "hcpcs_parse_partitions_map.sh"
  "hcpcs_parse_partitions_state.sh"
)

_missing=0
for _f in "${_required[@]}"; do
  if [[ ! -e "${_script_dir}/${_f}" ]]; then
    gsc_log_error "Missing required file: ${_f}"
    _missing=1
    continue
  fi
  if [[ "${_f}" == *.sh && ! -x "${_script_dir}/${_f}" ]]; then
    gsc_log_warn "Not executable: ${_f} (fixing chmod +x)"
    chmod +x "${_script_dir}/${_f}" || true
  fi
done

if [[ "${_missing}" -ne 0 ]]; then
  gsc_die "Selfcheck failed: missing required files"
fi

gsc_log_success "Selfcheck passed"
