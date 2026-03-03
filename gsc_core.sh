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

set -euo pipefail
IFS=$'\n\t'

# Prevent multiple sourcing
if [[ -n "${_GSC_CORE_SOURCED:-}" ]]; then
  return 0
fi
_GSC_CORE_SOURCED=1

# -----------------------------
# Dependency Checks
# -----------------------------
gsc_require() {
  local _missing=()
  local _cmd
  for _cmd in "$@"; do
    if ! command -v "${_cmd}" >/dev/null 2>&1; then
      _missing+=("${_cmd}")
    fi
  done

  if [[ ${#_missing[@]} -gt 0 ]]; then
    gsc_log_error "Missing required dependencies: ${_missing[*]}"
    exit 1
  fi
}

gsc_require_root() {
  if [[ $EUID -ne 0 ]]; then
    gsc_log_error "This script must be run as root (or with sudo)."
    exit 1
  fi
}

# -----------------------------
# Strict Mode Helper
# -----------------------------
# Call this at the start of any script that sources gsc_core.sh
gsc_strict_mode() {
  set -euo pipefail
  IFS=$'\n\t'
}

# -----------------------------
# Logging
# -----------------------------
_gsc_enable_color=1

gsc_log() {
  local _level="$1"
  local _msg="$2"
  local _color_code="\x1b[0m"

  if [[ "${_gsc_enable_color}" -eq 1 ]]; then
    case "${_level}" in
      INFO) _color_code="\x1b[32m" ;; # Green
      WARN) _color_code="\x1b[33m" ;; # Yellow
      ERROR) _color_code="\x1b[31m" ;; # Red
      CRITICAL) _color_code="\x1b[41;97m" ;; # White on Red
      ACTION) _color_code="\x1b[36m" ;; # Cyan
      OK) _color_code="\x1b[32m" ;; # Green
    esac
    printf "${_color_code}[%s]\x1b[0m %s\n" "${_level}" "${_msg}" >&2
  else
    printf "[%s] %s\n" "${_level}" "${_msg}" >&2
  fi
}

# Aliases for convenience (prints to stderr)
gsc_log_info()      { gsc_log INFO "$*" ;}
gsc_log_warn()      { gsc_log WARN "$*" ;}
gsc_log_error()     { gsc_log ERROR "$*" ;}
gsc_log_critical()  { gsc_log CRITICAL "$*" ;}
gsc_log_action()    { gsc_log ACTION "$*" ;}
gsc_log_ok()        { gsc_log OK "$*" ;}
gsc_log_success()   { gsc_log OK "$*" ;}

# For logging into a specific file (not stdout/stderr)
gsc_loga() {
  printf '%s\n' "$*" >> "${_output_file}"
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

gsc_is_empty() {
  local _val="${1:-}"
  if [[ -z "${_val}" || "${_val}" == "null" ]]; then
    printf 'true\n'
  else
    printf 'false\n'
  fi
}

gsc_is_number() {
  local _val="${1:-}"
  if [[ "${_val}" =~ ^-?[0-9]+$ ]]; then printf 'true\n'; else printf 'false\n'; fi
}

gsc_is_float() {
  local _val="${1:-}"
  if [[ "${_val}" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then printf 'true\n'; else printf 'false\n'; fi
}

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

gsc_rotate_log() {
  local _log_file="$1"
  if [[ -f "${_log_file}" ]]; then
    mv "${_log_file}" "${_log_file}.$(date +%Y%m%d_%H%M%S)"
  fi
}

gsc_truncate_log() {
  local _log_file="$1"
  local _lines="${2:-1000}"
  if [[ -f "${_log_file}" ]]; then
    # Keep only the last N lines, useful for very large logs
    tail -n "${_lines}" "${_log_file}" > "${_log_file}.tmp" && mv "${_log_file}.tmp" "${_log_file}"
  fi
}

# -----------------------------
# Temporary directory management
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

gsc_add_tmp_dir() {
  # Usage: gsc_add_tmp_dir <directory_path>
  # Adds a directory to the list of temporary directories to be cleaned up on exit.
  local _d="$1"
  [[ -d "${_d}" ]] && _gsc_tmp_dirs+=("${_d}")
}

gsc_cleanup() {
  local _d
  for _d in "${_gsc_tmp_dirs[@]:-}"; do
    rm -rf -- "${_d}" 2>/dev/null || true
  done
  # Wipe sensitive memory
  _GSC_SUDO_PASS_VAULTED=""
}

# -----------------------------
# Secure Sudo Management
# -----------------------------
_GSC_SUDO_PASS_VAULTED=""

gsc_prompt_sudo_password() {
  # If already vaulted, or if sudo works without password, skip
  if [[ -n "${_GSC_SUDO_PASS_VAULTED}" ]] || sudo -n true 2>/dev/null; then
    return 0
  fi

  local _pass
  printf "Password for sudo: " >&2
  read -rs _pass
  printf "\n" >&2

  if [[ -n "${_pass}" ]]; then
    _GSC_SUDO_PASS_VAULTED=$(gsc_vault_encrypt "${_pass}")
  fi
}

gsc_sudo() {
  # Usage: gsc_sudo <command> [args...]
  if sudo -n true 2>/dev/null; then
    sudo "$@"
  elif [[ -n "${_GSC_SUDO_PASS_VAULTED}" ]]; then
    gsc_vault_decrypt "${_GSC_SUDO_PASS_VAULTED}" | sudo -S "$@"
  else
    # Fallback to interactive prompt if not vaulted
    sudo "$@"
  fi
}

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
  gsc_die "Neither podman nor docker found in PATH."
}

gsc_detect_container_runtime() {
  local _runtime
  _runtime=$(gsc_detect_engine)
  printf '%s\n' "${_runtime}"
}

gsc_collect_container_ports() {
  _gsc_excluded_ports=("${_gsc_reserved_ports[@]}")
  local _line _tok _hp _runtime

  for _runtime in podman docker; do
    if command -v "${_runtime}" >/dev/null 2>&1; then
      # Use a more reliable way to extract host ports from the runtime
      # format '{{.Ports}}' returns strings like: 0.0.0.0:9090->9090/tcp, :::9091->9091/tcp
      while read -r _line; do
        [[ -z "${_line}" ]] && continue
        # Replace commas with spaces to iterate through multiple mappings
        local _mappings="${_line//,/ }"
        for _tok in ${_mappings}; do
          if [[ "${_tok}" == *"->"* ]]; then
            _hp="${_tok%%->*}"   # Get part before arrow: e.g. 0.0.0.0:9090 or :::9091
            _hp="${_hp##*:}"     # Get port number: e.g. 9090
            _gsc_excluded_ports+=("${_hp}")
          elif [[ "${_tok}" == *"/tcp" ]]; then # e.g. 9090/tcp
            _hp="${_tok%%/*}"
            _gsc_excluded_ports+=("${_hp}")
          fi
        done
      done < <("${_runtime}" ps --format '{{.Ports}}' 2>/dev/null || true)
    fi
  done

  if ((${#_gsc_excluded_ports[@]} > 1)); then
    local -A _seen=(); local _uniq=(); local _p
    for _p in "${_gsc_excluded_ports[@]}"; do
      if [[ -z "${_seen[${_p}]:-}" ]]; then
        _uniq+=("${_p}")
        _seen["${_p}"]=1
      fi
    done
    _gsc_excluded_ports=("${_uniq[@]}")
  fi
}

# -----------------------------
# Error Handling
# -----------------------------
gsc_die() {
  gsc_log_error "$*"
  exit 1
}

# -----------------------------
# File System
# -----------------------------
# robust find with globbing and escaping for paths with spaces
gsc_find_file() {
  local _dir="$1" _pattern="$2"
  find "${_dir}" -maxdepth 5 -type f -name "${_pattern}" -print -quit 2>/dev/null
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

  # Fast path: Native Bash integer comparison
  if [[ "${_val}" =~ ^-?[0-9]+$ ]] && [[ "${_lim}" =~ ^-?[0-9]+$ ]]; then
    case "${_op}" in
      ">")  (( _val >  _lim )) && { printf '%s\n' "${_val} > ${_lim}";  return 0; } ;;
      "<")  (( _val <  _lim )) && { printf '%s\n' "${_val} < ${_lim}";  return 0; } ;;
      ">=") (( _val >= _lim )) && { printf '%s\n' "${_val} >= ${_lim}"; return 0; } ;;
      "<=") (( _val <= _lim )) && { printf '%s\n' "${_val} <= ${_lim}"; return 0; } ;;
      "==") (( _val == _lim )) && { printf '%s\n' "${_val} == ${_lim}"; return 0; } ;;
      "!=") (( _val != _lim )) && { printf '%s\n' "${_val} != ${_lim}"; return 0; } ;;
    esac
  fi

  # Floating point path: Use bc if available
  if command -v bc >/dev/null 2>&1; then
    local _res
    _res=$(echo "if (${_val} ${_op} ${_lim}) 1 else 0" | bc 2>/dev/null)
    if [[ "${_res}" == "1" ]]; then
      printf '%s\n' "${_val} ${_op} ${_lim}"
      return 0
    fi
    return 1
  fi

  # Optimized fallback: gsc_calc
  local _bin
  _bin="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gsc_calc"
  if [[ -x "${_bin}" ]]; then
    local _out
    _out=$("${_bin}" -op "${_op}" "${_val}" "${_lim}" 2>/dev/null)
    if [[ -n "${_out}" ]]; then
      printf '%s\n' "${_out}"
      return 0
    fi
  fi

  return 1
}

gsc_arithmetic() {
  # Usage: gsc_arithmetic <value1> <operator> <value2>
  # Performs arithmetic and prints result to stdout.
  local _v1="$1"
  local _op="$2"
  local _v2="$3"

  # Fast path: Native Bash integer math
  if [[ "${_v1}" =~ ^-?[0-9]+$ ]] && [[ "${_v2}" =~ ^-?[0-9]+$ ]] && [[ "${_op}" =~ ^[+\-*/%]$ ]]; then
    # Prevent division by zero
    if [[ "${_op}" == "/" || "${_op}" == "%" ]] && [[ "${_v2}" == "0" ]]; then
       return 1
    fi
    echo $(( _v1 ${_op} _v2 ))
    return 0
  fi

  # Floating point path: Use bc if available
  if command -v bc >/dev/null 2>&1; then
    echo "scale=2; ${_v1} ${_op} ${_v2}" | bc 2>/dev/null && return 0
  fi

  # Fallback: gsc_calc
  local _bin
  _bin="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gsc_calc"
  if [[ -x "${_bin}" ]]; then
    "${_bin}" -op "${_op}" "${_v1}" "${_v2}" 2>/dev/null
    return $?
  fi

  return 1
}

# -----------------------------
# Bytes & Storage
# -----------------------------
_GSC_B_ORDER=(B K M G T P E Z Y) # Bytes, Kilo, Mega, Giga, Tera, Peta, Exa, Zetta, Yotta
_GSC_B_ORDER_MAP=(1 1024 1048576 1073741824 1099511627776 1125899906842624 1152921504606846976)

gsc_pretty_bytes() {
  local _bytes="$1"
  local _suffix=""
  local _scale=1
  
  if (( _bytes == 0 )); then
    echo "0B"
    return
  fi

  # Find the largest unit that results in a value >= 1
  for ((i=${#_GSC_B_ORDER_MAP[@]}-1; i>=0; i--)); do
    _scale=${_GSC_B_ORDER_MAP[$i]}
    _suffix=${_GSC_B_ORDER[$i]}
    if (( _bytes >= _scale )); then
      break
    fi
  done
  
  local _val=$(echo "scale=1; ${_bytes} / ${_scale}" | bc)
  # Remove trailing .0 if present
  echo "${_val}" | sed 's/\.0$//' "${_suffix}"
}

# Converts human readable bytes (e.g., "1G", "50M") to KB
gsc_parse_bytes_to_kb() {
    local _size="$1"
    local _value _unit_char _unit_multiplier=1 _num_val

    # Extract number and unit
    if [[ "${_size}" =~ ^([0-9.]+)([KMGTPEZY]?B?)$ ]]; then
        _value="${BASH_REMATCH[1]}"
        _unit_char="${BASH_REMATCH[2]}"
    else
        echo "0"
        return 1
    fi

    # Handle optional 'B' in unit
    if [[ "${_unit_char}" == *B ]]; then
        _unit_char="${_unit_char%B}"
    fi

    case "${_unit_char}" in
        "K") _unit_multiplier=1 ;;
        "M") _unit_multiplier=$((1024)) ;;
        "G") _unit_multiplier=$((1024 * 1024)) ;;
        "T") _unit_multiplier=$((1024 * 1024 * 1024)) ;;
        "P") _unit_multiplier=$((1024 * 1024 * 1024 * 1024)) ;;
        "E") _unit_multiplier=$((1024 * 1024 * 1024 * 1024 * 1024)) ;;
        "Z") _unit_multiplier=$((1024 * 1024 * 1024 * 1024 * 1024 * 1024)) ;;
        "Y") _unit_multiplier=$((1024 * 1024 * 1024 * 1024 * 1024 * 1024 * 1024)) ;;
        "") _unit_multiplier=1 # Assume KB if no unit
        ;;
        *) echo "0"; return 1 ;; # Unknown unit
    esac

    # Perform multiplication using bc for floating point if needed
    _num_val=$(echo "scale=0; ${_value} * ${_unit_multiplier}" | bc)
    echo "${_num_val}"
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
}

# -----------------------------
# Reserved Ports (Prometheus exporters)
# -----------------------------
_gsc_reserved_ports=(9093 9100 8080 9115 9116 9104)

_gsc_excluded_ports=()
