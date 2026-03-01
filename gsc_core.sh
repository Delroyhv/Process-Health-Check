#!/usr/bin/env bash
#
# gsc_core.sh - Core runtime for GSC bash tools
#
# Goals:
#  - strict mode helpers
#  - consistent logging
#  - dependency checks
#  - safe tempdirs + cleanup traps
#  - container engine abstraction (docker/podman)
#  - safe tar extraction helpers
#
# Version: 1.9.1
#

# Guard against multiple sourcing
if [[ -n "${_gsc_core_loaded:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_gsc_core_loaded=1

# -----------------------------
# Strict mode (opt-in)
# -----------------------------
# Call gsc_strict_mode near the top of scripts. We do not force it globally here
# because some legacy scripts rely on unset vars.

gsc_strict_mode() {
  set -euo pipefail
  IFS=$'\n\t'
}

# -----------------------------
# Color + logging
# -----------------------------
: "${GSC_NO_COLOR:=0}"
: "${_gsc_enable_color:=1}"
: "${_gsc_debug:=0}"

_gsc__use_color() {
  [[ "${GSC_NO_COLOR}" -eq 1 ]] && return 1
  [[ "${_gsc_enable_color}" -eq 0 ]] && return 1
  [[ -t 2 ]] || return 1
  return 0
}

_gsc__log_line() {
  # $1=level $2=msg  — all labels padded to 10 chars for uniform screen output
  local _lvl="$1"; shift
  local _msg="$*"

  case "${_lvl}" in
  INFO)
    if _gsc__use_color; then printf '\033[97m[INFO    ]\033[0m %s\n' "${_msg}" >&2; else printf '[INFO    ] %s\n' "${_msg}" >&2; fi ;;
  NOTICE)
    if _gsc__use_color; then printf '\033[36m[NOTICE  ]\033[0m %s\n' "${_msg}" >&2; else printf '[NOTICE  ] %s\n' "${_msg}" >&2; fi ;;
  WARN)
    if _gsc__use_color; then printf '\033[33m[WARNING ]\033[0m %s\n' "${_msg}" >&2; else printf '[WARNING ] %s\n' "${_msg}" >&2; fi ;;
  ERROR)
    if _gsc__use_color; then printf '\033[1;31m[ERROR   ]\033[0m %s\n' "${_msg}" >&2; else printf '[ERROR   ] %s\n' "${_msg}" >&2; fi ;;
  CRITICAL)
    if _gsc__use_color; then printf '\033[1;101;97m[CRITICAL]\033[0m %s\n' "${_msg}" >&2; else printf '[CRITICAL] %s\n' "${_msg}" >&2; fi ;;
  OK)
    if _gsc__use_color; then printf '\033[32m[ OK     ]\033[0m %s\n' "${_msg}" >&2; else printf '[ OK     ] %s\n' "${_msg}" >&2; fi ;;
  ACTION)
    if _gsc__use_color; then printf '\033[38;2;37;99;235m[ACTION  ]\033[0m %s\n' "${_msg}" >&2; else printf '[ACTION  ] %s\n' "${_msg}" >&2; fi ;;
  *)
    printf '[%s] %s\n' "${_lvl}" "${_msg}" >&2 ;;
  esac

  if [[ -n "${_log_file_name:-}" ]]; then
    printf '[%s] %s\n' "${_lvl}" "${_msg}" >>"${_log_file_name}" 2>/dev/null || true
  fi
}

gsc_log_info()     { _gsc__log_line INFO     "$*"; }
gsc_log_notice()   { _gsc__log_line NOTICE   "$*"; }
gsc_log_warn()     { _gsc__log_line WARN     "$*"; }
gsc_log_error()    { _gsc__log_line ERROR    "$*"; }
gsc_log_critical() { _gsc__log_line CRITICAL "$*"; }
gsc_log_ok()       { _gsc__log_line OK       "$*"; }
gsc_log_success()  { _gsc__log_line OK       "$*"; }  # alias for backward compat
gsc_log_action()   { _gsc__log_line ACTION   "$*"; }

gsc_die() {
  gsc_log_error "$*"
  exit 1
}

# -----------------------------
# Common helpers
# -----------------------------

gsc_require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  gsc_die "This script must be run as root (sudo)."
  fi
}

gsc_require_cmd() {
  local _missing=0
  local _c
  for _c in "$@"; do
  if ! command -v "${_c}" >/dev/null 2>&1; then
  gsc_log_error "Missing required command: ${_c}"
  _missing=1
  fi
  done
  [[ "${_missing}" -eq 0 ]] || gsc_die "Install missing dependencies and retry."
}

# -----------------------------
# Tempdir + cleanup
# -----------------------------
_gsc_tmp_dirs=()

gsc_mktempdir() {
  local _d
  _d="$(mktemp -d 2>/dev/null || true)"
  if [[ -z "${_d}" ]]; then
  _d="/tmp/gsc.$$.${RANDOM}"
  mkdir -p "${_d}" || gsc_die "Unable to create temp dir: ${_d}"
  fi
  _gsc_tmp_dirs+=("${_d}")
  printf '%s\n' "${_d}"
}

gsc_cleanup() {
  local _d
  for _d in "${_gsc_tmp_dirs[@]:-}"; do
  rm -rf -- "${_d}" 2>/dev/null || true
  done
}

# Script using gsc_core should set this trap (recommended):
#  trap gsc_cleanup EXIT

# -----------------------------
# Container engine abstraction
# -----------------------------

gsc_detect_engine() {
  # Echoes: podman|docker or dies.
  if command -v podman >/dev/null 2>&1; then
  printf '%s\n' podman
  return 0
  fi
  if command -v docker >/dev/null 2>&1; then
  printf '%s\n' docker
  return 0
  fi
  gsc_die "Neither podman nor docker found."
}

gsc_container_rm_if_exists() {
  # args: engine name
  local _engine="$1"; shift
  local _name="$1"; shift || true

  case "${_engine}" in
  podman)
  podman rm -f "${_name}" >/dev/null 2>&1 || true
  ;;
  docker)
  docker rm -f "${_name}" >/dev/null 2>&1 || true
  ;;
  *)
  gsc_die "Unknown container engine: ${_engine}"
  ;;
  esac
}

gsc_container_cleanup() {
  # Usage: gsc_container_cleanup <runtime> <pattern> <override_confirm> [cleanup_volumes] [base_dir]
  local _runtime="$1"
  local _pattern="$2"
  local _override="$3"
  local _volumes="${4:-0}"
  local _base_dir="${5:-}"

  local _containers
  _containers=$("${_runtime}" ps -a --format '{{.Names}}' | grep -E "${_pattern}" || true)

  if [[ -z "${_containers}" ]]; then
    gsc_log_info "No containers matching '${_pattern}' found to clean up."
    return 0
  fi

  if [[ "${_override}" != "y" ]]; then
    echo "WARNING: This will stop and remove the following containers:"
    echo "${_containers}"
    [[ "${_volumes}" -eq 1 ]] && echo "And DELETE their associated data directories."
    
    local _ans
    read -p "Are you sure? (y/N): " _ans
    [[ "${_ans,,}" != "y" ]] && gsc_die "Cleanup cancelled."
    read -p "CONFIRM AGAIN: Are you REALLY sure? (y/N): " _ans
    [[ "${_ans,,}" != "y" ]] && gsc_die "Cleanup cancelled."
  fi

  local _name
  for _name in ${_containers}; do
    gsc_log_info "Stopping and removing container: ${_name}"
    "${_runtime}" stop "${_name}" >/dev/null 2>&1 || true
    "${_runtime}" rm -f "${_name}" >/dev/null 2>&1 || true

    if [[ "${_volumes}" -eq 1 ]]; then
      local _target=""
      if [[ "${_name}" =~ ^gsc_prometheus_ ]]; then
        # gsc_prometheus_CUSTOMER_SR_PORT
        local _cust _sr
        _cust=$(echo "${_name}" | cut -d'_' -f3)
        _sr=$(echo "${_name}" | cut -d'_' -f4)
        [[ -n "${_base_dir}" ]] && _target="${_base_dir}/${_cust}/${_sr}"
      elif [[ "${_name}" == "grafana" ]]; then
        # Grafana deletes local dashboards/provisioning
        [[ -d "dashboards" ]] && rm -rf "dashboards"
        [[ -d "provisioning" ]] && rm -rf "provisioning"
        [[ -f "docker-compose.yaml" ]] && rm -f "docker-compose.yaml"
        gsc_log_info "Deleted local Grafana configuration directories."
      fi

      if [[ -n "${_target}" && -d "${_target}" ]]; then
        gsc_log_info "Deleting data directory: ${_target}"
        rm -rf "${_target}"
      fi
    fi
  done

  gsc_log_ok "Cleanup complete."
}

# -----------------------------
# Safe tar extraction
# -----------------------------

gsc_tar_extract_xz() {
  # args: archive dest_dir [strip_components]
  local _archive="$1"; shift
  local _dest="$1"; shift
  local _strip="${1:-0}"

  [[ -f "${_archive}" ]] || gsc_die "Archive not found: ${_archive}"
  mkdir -p "${_dest}" || gsc_die "Unable to create dest dir: ${_dest}"

  # Security: avoid ownership restoration; optionally strip components
  if [[ "${_strip}" -gt 0 ]]; then
  tar --no-same-owner --no-same-permissions --strip-components="${_strip}" -xJf "${_archive}" -C "${_dest}"
  else
  tar --no-same-owner --no-same-permissions -xJf "${_archive}" -C "${_dest}"
  fi
}

# -----------------------------
# JSON helpers
# -----------------------------
gsc_build_json_from_matches() {
  # Usage: gsc_build_json_from_matches <search_dir> <iname_glob> <out_json> [mode]
  # mode: "array" (default) -> slurp all matches into JSON array
  #  "one"  -> pretty-print first match only
  local _search_dir="$1"
  local _glob="$2"
  local _out_json="$3"
  local _mode="${4:-array}"

  local -a _files=()
  mapfile -t _files < <(find "${_search_dir}" -type f -iname "${_glob}" | sort)

  if [[ ${#_files[@]} -eq 0 ]]; then
  gsc_log_warn "No files matched: ${_search_dir}/**/${_glob}"
  return 1
  fi

  gsc_log_info "Building ${_out_json} from ${#_files[@]} file(s) matching: ${_glob}"

  if [[ "${_mode}" == "one" ]]; then
  jq -S . "${_files[0]}" > "${_out_json}"
  gsc_log_success "Wrote ${_out_json} (from first match: ${_files[0]})"
  return 0
  fi

  # Combine many JSON docs into an array
  jq -S -s '.' "${_files[@]}" > "${_out_json}"
  gsc_log_success "Wrote ${_out_json} (array of ${#_files[@]} documents)"
  return 0
}

gsc_prep_partition_json_and_parse() {
  # Usage: gsc_prep_partition_json_and_parse [search_dir] [out_map] [out_state]
  local _search_dir="${1:-cluster_triage}"
  local _out_map="${2:-partMap.json}"
  local _out_state="${3:-partState.json}"

  gsc_require jq find

  [[ -d "${_search_dir}" ]] || { gsc_log_warn "Directory not found: ${_search_dir}"; return 1; }

  # Map
  if gsc_build_json_from_matches "${_search_dir}" "*map*.json" "${_out_map}" "array"; then
  if [[ -x "./hcpcs_parse_partitions_map.sh" ]]; then
  gsc_log_info "Running: ./hcpcs_parse_partitions_map.sh -f ${_out_map}"
  ./hcpcs_parse_partitions_map.sh -f "${_out_map}"
  gsc_log_success "Parsed partition map"
  elif [[ -x "./hcpcs_parse_partitions_map.sh" ]]; then
  gsc_log_info "Running: ./hcpcs_parse_partitions_map.sh -f ${_out_map}"
  ./hcpcs_parse_partitions_map.sh -f "${_out_map}"
  gsc_log_success "Parsed partition map"
  else
  gsc_log_warn "Missing or not executable: ./hcpcs_parse_partitions_map.sh"
  fi
  fi

  # State
  if gsc_build_json_from_matches "${_search_dir}" "*state*.json" "${_out_state}" "array"; then
  if [[ -x "${_bundle_dir}/hcpcs_parse_partitions_state.sh" ]]; then
  gsc_log_info "Running: ${_bundle_dir}/hcpcs_parse_partitions_state.sh -f ${_out_state}"
  "${_bundle_dir}/hcpcs_parse_partitions_state.sh" -f "${_out_state}"
  gsc_log_success "Parsed partition state"
  else
  gsc_log_warn "Missing or not executable: ${_bundle_dir}/hcpcs_parse_partitions_state.sh"
  fi
  fi
}

# -----------------------------
# Dependency checks
# -----------------------------
gsc_require() {
  # Usage: gsc_require <cmd> [cmd ...]
  local _cmd
  for _cmd in "$@"; do
  if ! command -v "${_cmd}" >/dev/null 2>&1; then
  gsc_die "Missing dependency: ${_cmd}"
  fi
  done
}

# -----------------------------
# Tee/debug/file-search/validation helpers
# -----------------------------

# Write a message to _output_file (if set); echo to screen only for
# high-level prefixes (CRITICAL/WARNING/ERROR/NOTICE/INFO:), formatted with
# uniform colored brackets via _gsc__log_line. Detail lines go to file only.
gsc_loga() {
  local _msg="$*"
  if [[ -n "${_output_file:-}" ]]; then
    printf '%s\n' "${_msg}" >> "${_output_file}"
    if   [[ "${_msg}" =~ ^CRITICAL ]]; then _gsc__log_line CRITICAL "${_msg#*: }"
    elif [[ "${_msg}" =~ ^WARNING  ]]; then _gsc__log_line WARN     "${_msg#WARNING: }"
    elif [[ "${_msg}" =~ ^ERROR    ]]; then _gsc__log_line ERROR    "${_msg#ERROR: }"
    elif [[ "${_msg}" =~ ^NOTICE   ]]; then _gsc__log_line NOTICE   "${_msg#NOTICE: }"
    elif [[ "${_msg}" =~ ^INFO:    ]]; then _gsc__log_line INFO     "${_msg#INFO: }"
    fi
  else
    printf '%s\n' "${_msg}"
  fi
}

# Conditional debug output (checks _debug variable)
gsc_log_debug() {
  if [[ "${_debug:-0}" != "0" ]]; then
    _gsc__log_line INFO "[DEBUG] $*"
  fi
}

# Find a file whose name contains _pattern under _dir
gsc_find_file() {
  local _dir="$1"
  local _pattern="$2"
  find "${_dir}" -name "*${_pattern}*" 2>/dev/null | head -1
}

# Returns "true" if value is empty or null, "false" otherwise
gsc_is_empty() {
  local _val="${1:-}"
  if [[ -z "${_val}" || "${_val}" == "null" ]]; then
    printf 'true\n'
  else
    printf 'false\n'
  fi
}

# Returns "true" if value is an integer, "false" otherwise
gsc_is_number() {
  local _val="${1:-}"
  if [[ "${_val}" =~ ^-?[0-9]+$ ]]; then printf 'true\n'; else printf 'false\n'; fi
}

# Returns "true" if value is a float/decimal, "false" otherwise
gsc_is_float() {
  local _val="${1:-}"
  if [[ "${_val}" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then printf 'true\n'; else printf 'false\n'; fi
}

# Returns "true" if $1 is valid JSON, "false" otherwise
gsc_is_json() {
  printf '%s\n' "${1:-}" | jq -e . >/dev/null 2>&1 && printf 'true\n' || printf 'false\n'
}

# -----------------------------
# Partition artifacts (map/state/seed) prep + parse
# -----------------------------
gsc_prep_partition_artifacts_and_parse() {
  # Usage:
  #   gsc_prep_partition_artifacts_and_parse [search_dir] [support_dir]
  #
  # Creates (when matches exist):
  #   <support_dir>/partitionStateProperties.txt  from *seed*.json (pretty JSON per file)
  #   <support_dir>/partitionMap.json            from *map*.json   (slurped array)
  #   <support_dir>/partitionState.json          from *state*.json (slurped array)
  #
  # Then runs:
  #   hcpcs_parse_partitions_mp.sh (if present) or hcpcs_parse_partitions_map.sh on partitionMap.json
  #   hcpcs_parse_partitions_state.sh on partitionState.json

  local _search_dir="${1:-cluster_triage}"
  local _support_dir="${2:-supportLogs}"
  local _bundle_dir
  _bundle_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  gsc_require jq find

  [[ -d "${_search_dir}" ]] || {
    gsc_log_warn "Directory not found: ${_search_dir}"
    return 1
  }

  mkdir -p "${_support_dir}"

  local _seed_out="${_support_dir}/partitionStateProperties.txt"
  local _map_out="${_support_dir}/partitionMap.json"
  local _state_out="${_support_dir}/partitionState.json"

  # ---- SEED properties ------------------------------------------------------
  local -a _seed_files=()
  mapfile -t _seed_files < <(find "${_search_dir}" -type f -iname "*seed*.json" | sort)
  if [[ ${#_seed_files[@]} -gt 0 ]]; then
    : > "${_seed_out}"
    gsc_log_info "Building ${_seed_out} from ${#_seed_files[@]} file(s) matching: *seed*.json"
    local _f
    for _f in "${_seed_files[@]}"; do
      {
        printf "\n=========================================================\n"
        printf "FILE: %s\n" "${_f}"
        printf "=========================================================\n"
        jq -S . "${_f}"
      } >> "${_seed_out}"
    done
    gsc_log_success "Wrote ${_seed_out}"
  else
    gsc_log_info "No seed files matched (*seed*.json); skipping ${_seed_out}"
  fi

# ---- Map JSON -------------------------------------------------------------
if gsc_build_json_from_matches "${_search_dir}" "*map*.json" "${_map_out}" "array"; then
  # Rotate/retain parser log (keep 2 backups) before overwriting
  gsc_rotate_log "${_support_dir}/partitionMap_parse.log" 2

  if [[ -x "${_bundle_dir}/hcpcs_parse_partitions_mp.sh" ]]; then
    gsc_log_info "Running: ${_bundle_dir}/hcpcs_parse_partitions_mp.sh -f ${_map_out}"
    "${_bundle_dir}/hcpcs_parse_partitions_mp.sh" -f "${_map_out}" | tee "${_support_dir}/partitionMap_parse.log"
    gsc_log_success "Parsed partition map (mp)"
  elif [[ -x "${_bundle_dir}/hcpcs_parse_partitions_map.sh" ]]; then
    gsc_log_info "Running: ${_bundle_dir}/hcpcs_parse_partitions_map.sh -f ${_map_out}"
    "${_bundle_dir}/hcpcs_parse_partitions_map.sh" -f "${_map_out}" | tee "${_support_dir}/partitionMap_parse.log"
    gsc_log_success "Parsed partition map"
  else
    gsc_log_warn "Missing or not executable: ${_bundle_dir}/hcpcs_parse_partitions_map.sh"
  fi
fi

  
# ---- State JSON -----------------------------------------------------------
if gsc_build_json_from_matches "${_search_dir}" "*state*.json" "${_state_out}" "array"; then
  # Rotate/retain parser log (keep 2 backups) before overwriting
  gsc_rotate_log "${_support_dir}/partitionState_parse.log" 2

  if [[ -x "${_bundle_dir}/hcpcs_parse_partitions_state.sh" ]]; then
    gsc_log_info "Running: ${_bundle_dir}/hcpcs_parse_partitions_state.sh -f ${_state_out}"
    "${_bundle_dir}/hcpcs_parse_partitions_state.sh" -f "${_state_out}" | tee "${_support_dir}/partitionState_parse.log"
    gsc_log_success "Parsed partition state"
  else
    gsc_log_warn "Missing or not executable: ${_bundle_dir}/hcpcs_parse_partitions_state.sh"
  fi
fi

  gsc_log_success "Partition artifacts prepared under: ${_support_dir}"
}

# -----------------------------
# Log rotation (timestamped backups)
# -----------------------------
gsc_rotate_log() {
  # Usage: gsc_rotate_log <file> [keep]
  # Keeps N timestamped backups: <file>.YYYYMMDD_HHMMSS (default keep=2)
  local _file="${1:-}"
  local _keep="${2:-2}"

  [[ -n "${_file}" ]] || return 0
  [[ -f "${_file}" ]] || return 0

  local _ts
  _ts="$(date +%Y%m%d_%H%M%S)"
  mv -f -- "${_file}" "${_file}.${_ts}" 2>/dev/null || return 0

  # Retention cleanup (keep newest N)
  local -a _backups=()
  mapfile -t _backups < <(ls -1t "${_file}."* 2>/dev/null || true)
  if (( ${#_backups[@]} > _keep )); then
    local _b
    for _b in "${_backups[@]:_keep}"; do
      rm -f -- "${_b}" 2>/dev/null || true
    done
  fi
}

gsc_truncate_log() {
  # Usage: gsc_truncate_log <file> [keep]
  local _file="${1:-}"
  local _keep="${2:-2}"
  [[ -n "${_file}" ]] || return 0
  gsc_rotate_log "${_file}" "${_keep}"
  : > "${_file}"
}

# -----------------------------
# Display / UI
# -----------------------------
_gsc_spinner_idx=0
gsc_spinner() {
  local -a _spin=("-" "\\" "|" "/")
  echo -ne "${_spin[$((_gsc_spinner_idx % 4))]} \r" >&2
  ((_gsc_spinner_idx++))
}

# -----------------------------
# Math / Comparison
# -----------------------------
gsc_compare_value() {
  # Usage: gsc_compare_value <value> <operator> <limit>
  # Returns the comparison string if true (e.g. "10 > 5"), else empty
  local _val="$1"
  local _op="$2"
  local _lim="$3"
  local _res=0

  # Optimized path using Go binary if present
  local _bin
  _bin="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gsc_calc"
  if [[ -x "${_bin}" ]]; then
    local _out
    _out=$("${_bin}" -op "${_op}" "${_val}" "${_lim}" 2>/dev/null)
    if [[ -n "${_out}" ]]; then
      printf '%s\n' "${_out}"
      return 0
    fi
    return 0
  fi

  # Fallback to bc or basic bash
  case "${_op}" in
    ">")  _res=$(echo "${_val} > ${_lim}" | bc 2>/dev/null || [ "${_val%.*}" -gt "${_lim%.*}" ] && echo 1 || echo 0) ;;
    "<")  _res=$(echo "${_val} < ${_lim}" | bc 2>/dev/null || [ "${_val%.*}" -lt "${_lim%.*}" ] && echo 1 || echo 0) ;;
    "==") _res=$(echo "${_val} == ${_lim}" | bc 2>/dev/null || [ "${_val}" = "${_lim}" ] && echo 1 || echo 0) ;;
    "!=") _res=$(echo "${_val} != ${_lim}" | bc 2>/dev/null || [ "${_val}" != "${_lim}" ] && echo 1 || echo 0) ;;
    *) return 1 ;;
  esac

  if [[ "${_res}" -eq 1 ]]; then
    printf '%s %s %s\n' "${_val}" "${_op}" "${_lim}"
  fi
}

gsc_arithmetic() {
  # Usage: gsc_arithmetic <val1> <operator> <val2>
  # Operator: +, -, *, /
  local _v1="$1"
  local _op="$2"
  local _v2="$3"

  # Optimized path
  local _bin
  _bin="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gsc_calc"
  if [[ -x "${_bin}" ]]; then
    "${_bin}" -op "${_op}" "${_v1}" "${_v2}" 2>/dev/null
    return $?
  fi

  # Fallback
  echo "scale=2; ${_v1} ${_op} ${_v2}" | bc 2>/dev/null || echo "$(( _v1 ${_op} _v2 ))"
}

# -----------------------------
# Secure Vault (AES-GCM)
# -----------------------------
gsc_vault_encrypt() {
  # Usage: gsc_vault_encrypt <plaintext>
  local _bin
  _bin="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gsc_vault"
  if [[ -x "${_bin}" ]]; then
    "${_bin}" -op encrypt "$1"
  else
    gsc_log_error "gsc_vault binary not found or not executable"
    return 1
  fi
}

gsc_vault_decrypt() {
  # Usage: gsc_vault_decrypt <ciphertext_hex>
  local _bin
  _bin="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gsc_vault"
  if [[ -x "${_bin}" ]]; then
    "${_bin}" -op decrypt "$1"
  else
    gsc_log_error "gsc_vault binary not found or not executable"
    return 1
  fi
}

# -----------------------------
# Timestamps / Date
# -----------------------------
gsc_get_date_format() {
  # Usage: gsc_get_date_format <epoch_seconds>
  # Output: e.g. 2024-08-19T20:10:30.781Z
  local _ts="${1:-$(date +%s)}"
  date -u -d "@${_ts}" +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -r "${_ts}" +'%Y-%m-%dT%H:%M:%SZ'
}

gsc_timestamp() {
  date +%Y-%m-%dT%H:%M:%S%z
}

# -----------------------------
# Progress tool detection
# -----------------------------
_have_pv=0
_have_progress=0

gsc_detect_progress_tools() {
  _have_pv=0
  _have_progress=0
  if command -v pv >/dev/null 2>&1; then _have_pv=1; fi
  if command -v progress >/dev/null 2>&1; then _have_progress=1; fi
  if [[ "${_have_pv}" -eq 1 ]]; then
    gsc_log_info "Detected 'pv' – will use it for progress display."
  elif [[ "${_have_progress}" -eq 1 ]]; then
    gsc_log_info "Detected 'progress' – will use it to monitor xz / tar."
  else
    gsc_log_info "Neither 'pv' nor 'progress' found – proceeding without progress display."
  fi
}

# -----------------------------
# JSON escape
# -----------------------------
gsc_json_escape() {
  local _text="$1"
  printf '"%s"' "$(printf '%s' "${_text}" | sed 's/\\/\\\\/g; s/"/\\"/g')"
}

# -----------------------------
# Container port helpers
# -----------------------------
_gsc_reserved_ports=(9093 9100 8080 9115 9116 9104)
_gsc_excluded_ports=()

gsc_detect_container_runtime() {
  if command -v podman >/dev/null 2>&1; then printf '%s\n' "podman"; return 0; fi
  if command -v docker >/dev/null 2>&1; then printf '%s\n' "docker"; return 0; fi
  return 1
}

gsc_collect_container_ports() {
  _gsc_excluded_ports=("${_gsc_reserved_ports[@]}")
  local _line _tok _hp _runtime

  for _runtime in podman docker; do
    if command -v "${_runtime}" >/dev/null 2>&1; then
      local _tmp
      _tmp="$(mktemp 2>/dev/null || printf '/tmp/gsc_%s_ports.%s' "${_runtime}" "$$")"
      "${_runtime}" ps --format '{{.Ports}}' 2>/dev/null > "${_tmp}" || true
      while IFS= read -r _line; do
        for _tok in ${_line}; do
          case "${_tok}" in
            *:*/*)
              _hp="${_tok%%->*}"; _hp="${_hp##*:}"
              if [[ "${_hp}" =~ ^[0-9]+$ ]]; then
                _gsc_excluded_ports+=("${_hp}")
              fi
              ;;
          esac
        done
      done < "${_tmp}"
      rm -f "${_tmp}"
    fi
  done

  if (( ${#_gsc_excluded_ports[@]} > 1 )); then
    local -A _seen=(); local _uniq=(); local _p
    for _p in "${_gsc_excluded_ports[@]}"; do
      if [[ -z "${_seen[${_p}]:-}" ]]; then _uniq+=("${_p}"); _seen["${_p}"]=1; fi
    done
    _gsc_excluded_ports=("${_uniq[@]}")
  fi
}

gsc_port_in_use() {
  local _p="$1" _ep
  for _ep in "${_gsc_excluded_ports[@]}"; do
    [[ "${_p}" -eq "${_ep}" ]] && return 0
  done
  if command -v ss >/dev/null 2>&1; then
    ss -tuln 2>/dev/null | awk 'NR>1 {print $5}' | grep -qE "(:|\\.)${_p}$" && return 0
  elif command -v netstat >/dev/null 2>&1; then
    netstat -tuln 2>/dev/null | awk 'NR>2 {print $4}' | grep -qE "(:|\\.)${_p}$" && return 0
  fi
  return 1
}

# -----------------------------
# Space estimation helpers
# -----------------------------
gsc_estimate_uncompressed_size() {
  local _archive="$1" _size=""
  [[ -f "${_archive}" ]] || { gsc_log_error "Archive not found for size estimation: ${_archive}"; return 1; }
  case "${_archive}" in
    *.xz)
      if command -v xz >/dev/null 2>&1; then
        _size="$(xz --robot -l -- "${_archive}" 2>/dev/null | awk '$1=="totals"{print $5}' | tail -n1 || true)"
      fi ;;
  esac
  if [[ -z "${_size}" || ! "${_size}" =~ ^[0-9]+$ ]]; then
    gsc_log_warn "Unable to estimate uncompressed size for ${_archive}; skipping space pre-check."
    return 1
  fi
  printf '%s\n' "${_size}"
}

gsc_check_extract_space() {
  local _archive="$1" _target_dir="$2"
  local _warn_pct="${3:-${GSC_SPACE_WARN_PCT:-10}}"
  local _fail_pct="${4:-${GSC_SPACE_FAIL_PCT:-5}}"
  [[ -f "${_archive}" ]] || { gsc_log_error "Archive not found: ${_archive}"; return 1; }
  mkdir -p "${_target_dir}"
  local _size
  _size="$(gsc_estimate_uncompressed_size "${_archive}")" || return 0
  local _df_line
  _df_line="$(df -P -B1 -- "${_target_dir}" 2>/dev/null | awk 'NR==2')" || { gsc_log_warn "Unable to determine filesystem space; skipping."; return 0; }
  local _fs_dev _fs_total _fs_used _fs_avail _fs_use _fs_mnt
  read -r _fs_dev _fs_total _fs_used _fs_avail _fs_use _fs_mnt <<<"${_df_line}"
  [[ "${_fs_total}" =~ ^[0-9]+$ && "${_fs_avail}" =~ ^[0-9]+$ && "${_fs_total}" -ne 0 ]] || { gsc_log_warn "Unexpected df output; skipping."; return 0; }
  local _free_after=$((_fs_avail - _size))
  if (( _free_after < 0 )); then
    gsc_log_error "Not enough space to extract ${_archive}: need ~$((_size/1048576)) MiB, only ~$((_fs_avail/1048576)) MiB available."
    return 2
  fi
  local _pct_after=$(( 100 * _free_after / _fs_total ))
  if (( _pct_after < _fail_pct )); then
    gsc_log_error "Extraction would leave ~$((_free_after/1048576)) MiB free (${_pct_after}%), below fail threshold ${_fail_pct}%."
    return 2
  elif (( _pct_after < _warn_pct )); then
    gsc_log_warn "Extraction will leave ~$((_free_after/1048576)) MiB free (${_pct_after}%), below warning threshold ${_warn_pct}%."
  fi
}

gsc_print_space_estimate() {
  local _archive="$1" _target_dir="$2" _size
  _size="$(gsc_estimate_uncompressed_size "${_archive}")" || return 1
  local _df_line
  _df_line="$(df -P -B1 -- "${_target_dir}" 2>/dev/null | awk 'NR==2')" || { gsc_log_warn "Unable to determine filesystem space."; return 1; }
  local _fs_dev _fs_total _fs_used _fs_avail _fs_use _fs_mnt
  read -r _fs_dev _fs_total _fs_used _fs_avail _fs_use _fs_mnt <<<"${_df_line}"
  if [[ ! "${_fs_total}" =~ ^[0-9]+$ || "${_fs_total}" -eq 0 ]]; then
    gsc_log_warn "Unexpected df total for ${_target_dir}; skipping estimate."
    return 1
  fi
  local _free_after=$((_fs_avail - _size))
  local _pct_after=$(( 100 * _free_after / _fs_total ))
  gsc_log_info "Estimate for ${_archive} -> ${_target_dir}: size≈$((_size/1048576)) MiB, free_before≈$((_fs_avail/1048576)) MiB, free_after≈$((_free_after/1048576)) MiB (~${_pct_after}% free)."
}

# -----------------------------
# HCPCS legacy globals + helpers
# -----------------------------
_username="admin"
_cluster_name=""
_realm=""
_passwd=""
_dir_name=""
_sc_user=""
_sc_passwd=""
_realm_def="openLDAP"
_token=""
_xsrf=""
_vertx=""
_cookie=""
_verbose="false"
_python_cmd="python"
_file_name=""
_port_num=""
_python_urllib="import urllib;print (urllib.quote(raw_input()))"
_debug=${_debug:-0}

check_python() {
  local _python3_ver _python2_ver
  _python3_ver="$(python3 -V 2>&1 || true)"
  _python2_ver="$(python2 -V 2>&1 || true)"
  if [[ "${_python3_ver}" == *"Python 3"* ]]; then
    _python_cmd="python3"
    _python_urllib="import urllib.parse; print (urllib.parse.quote(input()))"
  elif [[ "${_python2_ver}" == *"Python 2"* ]]; then
    : # python2 default
  else
    gsc_die "Cannot find python."
  fi
}

setLogFile() {
  local _log_fname="$1"
  [[ "${_log_fname}" == *.log ]] || _log_fname="${_log_fname}.log"
  _log_file_name="${_log_fname}"
}

log()  { printf '%s\n' "$1" > "${_log_file_name}" 2>/dev/null || true; }
loga() { printf '%s\n' "$1" >> "${_log_file_name}" 2>/dev/null || true; }
log2()  { _gsc__log_line INFO "$1"; printf '%s\n' "$1" > "${_log_file_name}" 2>/dev/null || true; }
log2a() { _gsc__log_line INFO "$1"; printf '%s\n' "$1" >> "${_log_file_name}" 2>/dev/null || true; }

debug() {
  if [[ "${_debug}" == "1" ]]; then
    gsc_log_info "$1"
    printf '%s\n' "$1" >> "${_log_file_name}" 2>/dev/null || true
    _gsc_debug=1
  fi
}

getOptions() {
  local _opt
  while getopts "c:u:p:r:d:v:s:w:h:f:n:" _opt; do
    case "${_opt}" in
      c) _cluster_name=${OPTARG} ;;
      u) _username=${OPTARG} ;;
      p) _passwd=${OPTARG} ;;
      r) _realm=${OPTARG} ;;
      d) _dir_name=${OPTARG} ;;
      v) _verbose="true" ;;
      s) _sc_user=${OPTARG} ;;
      w) _sc_passwd=${OPTARG} ;;
      f) _file_name=${OPTARG} ;;
      n) _port_num=${OPTARG} ;;
      h) usage; exit 0 ;;
      *) gsc_log_warn "getOptions: unknown flag -${_opt}"; usage; exit 1 ;;
    esac
  done
}

handleBasicOptions() {
  if [[ -z "${_realm}" ]]; then
    _realm="$( [[ "${_username}" == "admin" ]] && printf '%s' "local" || printf '%s' "${_realm_def}" )"
  fi
  [[ -n "${_cluster_name}" ]] || { gsc_log_error "option -c must be specified"; usage; exit 1; }
  [[ -n "${_passwd}" ]]       || { gsc_log_error "option -p must be specified"; usage; exit 1; }
  [[ -n "${_dir_name}" ]]     || _dir_name="supportLogs"
}

version2_5_or_greater() {
  local _reply _version _version_substr _new=1
  _reply="$(curl -s "http://${_cluster_name}:8889/api/foundry/setup")"
  [[ -n "${_reply}" ]] || { gsc_log_error "no reply from ${_cluster_name}"; exit 1; }
  _version="$(printf '%s' "${_reply}" | jq -r '.productVersion // empty' 2>/dev/null || true)"
  _version_substr="${_version:2:1}"
  [[ "${_version_substr}" -ge 5 ]] && _new=0
  printf '%s\n' "${_new}"
}

get_cookie() {
  local _cookie_response
  _cookie_response="$(curl -s -kc - "https://${_cluster_name}:9099/")"
  _xsrf="$(printf '%s' "${_cookie_response}" | grep XSRF-TOKEN | awk '{print $NF}')"
  _vertx="$(printf '%s' "${_cookie_response}" | grep vertx-web.session | awk '{print $NF}')"
  _cookie="XSRF-TOKEN=${_xsrf}; vertx-web.session=${_vertx}"
}

getAuthToken() {
  get_cookie
  [[ -n "${_xsrf}" ]] || { gsc_log_error "Unable to generate XSRF token"; exit 1; }
  _token="$(curl -s -k -X POST "https://${_cluster_name}:8000/auth/oauth" \
    -d grant_type=password -d username="${_username}" -d password="${_passwd}" \
    -d scope="*" -d realm="${_realm}" -d client_secret="client_secret" -d client_id="client_id" \
    | jq -r '.access_token // empty')"
  [[ -n "${_token}" ]] || { gsc_log_error "Unable to generate token for ${_username}@${_realm}"; exit 1; }
}

createDir() {
  if [[ ! -d "${_dir_name}" ]]; then
    gsc_log_info "Creating ${_dir_name} directory"
    mkdir -p "${_dir_name}" || gsc_die "Couldn't create ${_dir_name}."
  fi
}

hcpcs_json_body_from_file() {
  local _file="$1"
  [[ -r "${_file}" ]] || return 1
  # Strip lines starting with # (comments) and empty lines from the beginning until the first { or [
  sed -n '/^[[:space:]]*[{[]/,$p' "${_file}"
}

hcpcs_json_is_valid() {
  local _file="$1"
  [[ -s "${_file}" ]] || return 1
  hcpcs_json_body_from_file "${_file}" | jq empty >/dev/null 2>&1
}

# -----------------------------
# Auto-setup _log_file_name (once, at load time)
# -----------------------------
if [[ -z "${_log_file_name:-}" ]]; then
  _gsc_script_base="$(basename "${0:-gsc_script}")"
  _log_file_name="${_gsc_script_base%.*}.log"
fi
if [[ -n "${_log_file_name:-}" && -e "${_log_file_name}" ]]; then
  gsc_rotate_log "${_log_file_name}" 2
fi
