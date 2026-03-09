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
#

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
gsc_log_debug()     { if [[ "${_debug:-0}" == "1" || "${_debug:-0}" == "2" ]]; then gsc_log INFO "[DEBUG] $*"; fi; return 0; }

gsc_die() {
  gsc_log_error "$*"
  exit 1
}

# For logging into a specific file (not stdout/stderr)
gsc_loga() {
  if [[ -n "${_output_file:-}" ]]; then
    printf '%s\n' "$*" >> "${_output_file}"
  fi
}

# -----------------------------
# Display / UI
# -----------------------------
_gsc_spinner_idx=0
gsc_spinner() {
  local -a _spin=("-" "\\" "|" "/")
  echo -ne "${_spin[$((_gsc_spinner_idx % 4))]} \r" >&2
  ((_gsc_spinner_idx++)) || true
}

# -----------------------------
# File & Search
# -----------------------------
gsc_find_file() {
  # Usage: gsc_find_file <directory> <pattern>
  local _dir="$1"
  local _pat="$2"
  find "${_dir}" -type f -name "*${_pat}*" 2>/dev/null | sort -r | head -n 1
}

gsc_ver_gte() {
  # Returns 0 (true) if version string $1 >= $2 (up to 4-part: major.minor.patch.build)
  local _i _a _b
  local -a _v1 _v2
  IFS='.' read -ra _v1 <<< "$1"
  IFS='.' read -ra _v2 <<< "$2"
  for _i in 0 1 2 3; do
    _a=${_v1[_i]:-0}
    _b=${_v2[_i]:-0}
    (( _a > _b )) && return 0
    (( _a < _b )) && return 1
  done
  return 0
}

gsc_extract_flat() {
  # Usage: gsc_extract_flat <archive> [target_dir]
  # Extracts archive into target_dir, stripping one top-level directory if present.
  local _archive="$1"
  local _target="${2:-.}"

  if [[ -z "${_archive}" ]]; then
    gsc_log_error "gsc_extract_flat: archive argument is required"
    return 1
  fi

  if [[ ! -f "${_archive}" ]]; then
    gsc_log_error "gsc_extract_flat: archive not found: ${_archive}"
    return 1
  fi

  mkdir -p "${_target}"

  case "${_archive}" in
    *.zip)
      gsc_require unzip
      local _tmp
      _tmp=$(mktemp -d)             # staging dir; registered for safe cleanup on exit
      gsc_add_tmp_dir "${_tmp}"
      unzip -q "${_archive}" -d "${_tmp}"
      local -a _top_entries=()
      mapfile -t _top_entries < <(find "${_tmp}" -mindepth 1 -maxdepth 1)  # array-safe for names with spaces
      if [[ ${#_top_entries[@]} -eq 1 && -d "${_top_entries[0]}" ]]; then
        mv "${_top_entries[0]}"/.[!.]* "${_target}/" 2>/dev/null || true    # dotfiles first; suppress if none
        mv "${_top_entries[0]}"/* "${_target}/"                             # visible files
      else
        mv "${_tmp}"/* "${_target}/"  # multiple top-level entries; move all
      fi
      ;;
    *.tar.gz|*.tgz|*.tar.xz|*.tar.bz2|*.tar)
      gsc_require tar
      XZ_OPT="-T0" tar -xf "${_archive}" --strip-components=1 -C "${_target}"  # strip top-level; XZ_OPT enables multi-thread when blocks present
      ;;
    *)
      gsc_log_error "gsc_extract_flat: unsupported archive format: ${_archive}"
      return 1
      ;;
  esac

  gsc_log_info "Extracted ${_archive} -> ${_target}"
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

  # ---- SEED properties ----
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

  # ---- Map JSON ----
  if gsc_build_json_from_matches "${_search_dir}" "*map*.json" "${_map_out}" "array"; then
    gsc_rotate_log "${_support_dir}/partitionMap_parse.log" 2
    if [[ -x "${_bundle_dir}/hcpcs_parse_partitions_mp.sh" ]]; then
      "${_bundle_dir}/hcpcs_parse_partitions_mp.sh" -f "${_map_out}" | tee "${_support_dir}/partitionMap_parse.log" || true
    elif [[ -x "${_bundle_dir}/hcpcs_parse_partitions_map.sh" ]]; then
      "${_bundle_dir}/hcpcs_parse_partitions_map.sh" -f "${_map_out}" | tee "${_support_dir}/partitionMap_parse.log" || true
    fi
  fi

  # ---- State JSON ----
  if gsc_build_json_from_matches "${_search_dir}" "*state*.json" "${_state_out}" "array"; then
    gsc_rotate_log "${_support_dir}/partitionState_parse.log" 2
    if [[ -x "${_bundle_dir}/hcpcs_parse_partitions_state.sh" ]]; then
      "${_bundle_dir}/hcpcs_parse_partitions_state.sh" -f "${_state_out}" | tee "${_support_dir}/partitionState_parse.log" || true
    fi
  fi

  # ---- Split Events JSON (partition split history for growth analysis) ----
  local _split_out="${_support_dir}/partitionSplit.json"
  local -a _split_files=()
  mapfile -t _split_files < <(find "${_search_dir}" -type f -iname "*splitpartition*.json" ! -iname "*.err" | sort)
  if [[ ${#_split_files[@]} -gt 0 ]]; then
    gsc_log_info "Building ${_split_out} from ${#_split_files[@]} file(s) matching: *splitpartition*.json"
    jq -sc 'unique_by(.parentId)[]' "${_split_files[@]}" > "${_split_out}"
    local _split_count
    _split_count=$(wc -l < "${_split_out}")
    gsc_log_success "Wrote ${_split_out} (${_split_count} unique split events)"
  else
    gsc_log_info "No split event files matched (*splitpartition*.json); skipping ${_split_out}"
  fi
}

# -----------------------------
# Log management
# -----------------------------
gsc_rotate_log() {
  local _log_file="$1"
  local _keep="${2:-2}"
  [[ -f "${_log_file}" ]] || return 0
  mv "${_log_file}" "${_log_file}.$(date +%Y%m%d_%H%M%S)"
  local -a _backups=()
  mapfile -t _backups < <(ls -1t "${_log_file}."* 2>/dev/null || true)
  if (( ${#_backups[@]} > _keep )); then
    local _b
    for _b in "${_backups[@]:_keep}"; do rm -f -- "${_b}"; done
  fi
}

gsc_truncate_log() {
  local _log_file="$1"
  local _lines="${2:-1000}"
  if [[ -f "${_log_file}" ]]; then
    tail -n "${_lines}" "${_log_file}" > "${_log_file}.tmp" && mv "${_log_file}.tmp" "${_log_file}"
  fi
}

# -----------------------------
# Temporary directory management
# -----------------------------
_gsc_tmp_dirs=()
gsc_add_tmp_dir() { [[ -d "$1" ]] && _gsc_tmp_dirs+=("$1"); }
gsc_cleanup() {
  for _d in "${_gsc_tmp_dirs[@]:-}"; do rm -rf -- "${_d}" 2>/dev/null || true; done
  _GSC_SUDO_PASS_VAULTED=""
}

# -----------------------------
# Secure Sudo & Vault
# -----------------------------
_GSC_SUDO_PASS_VAULTED=""

gsc_vault_encrypt() {
  local _bin="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gsc_vault"
  if [[ -x "${_bin}" ]]; then "${_bin}" -op encrypt "$1"; else echo "$1"; fi
}

gsc_vault_decrypt() {
  local _bin="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gsc_vault"
  if [[ -x "${_bin}" ]]; then "${_bin}" -op decrypt "$1"; else echo "$1"; fi
}

gsc_prompt_sudo_password() {
  if [[ -n "${_GSC_SUDO_PASS_VAULTED}" ]] || sudo -n true 2>/dev/null; then return 0; fi
  local _pass; printf "Password for sudo: " >&2; read -rs _pass; printf "\n" >&2
  [[ -n "${_pass}" ]] && _GSC_SUDO_PASS_VAULTED=$(gsc_vault_encrypt "${_pass}")
}

gsc_sudo() {
  if sudo -n true 2>/dev/null; then sudo "$@"; elif [[ -n "${_GSC_SUDO_PASS_VAULTED}" ]]; then gsc_vault_decrypt "${_GSC_SUDO_PASS_VAULTED}" | sudo -S "$@"; else sudo "$@"; fi
}

# -----------------------------
# Container engine abstraction
# -----------------------------
gsc_detect_engine() {
  if command -v podman >/dev/null 2>&1; then echo podman; elif command -v docker >/dev/null 2>&1; then echo docker; else return 1; fi
}
gsc_detect_container_runtime() { gsc_detect_engine; }
gsc_container_rm_if_exists() {
  local _e="$1" _n="$2"
  [[ "$_e" == "podman" ]] && podman rm -f "$_n" >/dev/null 2>&1 || docker rm -f "$_n" >/dev/null 2>&1 || true
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
  fi

  local _name
  for _name in ${_containers}; do
    gsc_log_info "Stopping and removing container: ${_name}"
    "${_runtime}" stop "${_name}" >/dev/null 2>&1 || true
    "${_runtime}" rm -f "${_name}" >/dev/null 2>&1 || true

    # Clear port in healthcheck.conf if it exists in current dir
    if [[ "${_name}" =~ ^gsc_prometheus_ && -f "./healthcheck.conf" ]]; then
      sed -i 's/_prom_port="[0-9]*"/_prom_port=""/' "./healthcheck.conf" 2>/dev/null || true
      gsc_log_info "Cleared _prom_port in ./healthcheck.conf (port is now free)."
    fi

    if [[ "${_volumes}" -eq 1 ]]; then
      local _target=""
      if [[ "${_name}" =~ ^gsc_prometheus_ ]]; then
         _target="${_base_dir}"
      fi

      if [[ -n "${_target}" && -d "${_target}" ]]; then
        gsc_log_info "Deleting data directory: ${_target}"
        rm -rf "${_target}"
      fi
    fi
  done

  gsc_log_ok "Cleanup complete."
}

gsc_sanitize_name() {
  # Usage: gsc_sanitize_name <string>
  # Returns a string safe for Docker/Podman container names: [a-zA-Z0-9][a-zA-Z0-9_.-]*
  local _s="$1"
  _s=$(printf '%s' "${_s}" | sed 's/[^a-zA-Z0-9_.-]/_/g')
  if [[ ! "${_s}" =~ ^[a-zA-Z0-9] ]]; then
    _s="gsc_${_s}"
  fi
  printf '%s\n' "${_s}"
}

# -----------------------------
# Math / Comparison
# -----------------------------
gsc_compare_value() {
  local _val="$1" _op="$2" _lim="$3"
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
  if command -v bc >/dev/null 2>&1; then
    local _res=$(echo "if (${_val} ${_op} ${_lim}) 1 else 0" | bc 2>/dev/null)
    [[ "${_res}" == "1" ]] && { printf '%s\n' "${_val} ${_op} ${_lim}"; return 0; }
    return 1
  fi
  return 1
}

gsc_arithmetic() {
  local _v1="$1" _op="$2" _v2="$3"
  if [[ "${_v1}" =~ ^-?[0-9]+$ ]] && [[ "${_v2}" =~ ^-?[0-9]+$ ]] && [[ "${_op}" =~ ^[+\-*/%]$ ]]; then
    [[ ("${_op}" == "/" || "${_op}" == "%") && "${_v2}" == "0" ]] && return 1
    echo $(( _v1 ${_op} _v2 )); return 0
  fi
  if command -v bc >/dev/null 2>&1; then echo "scale=2; ${_v1} ${_op} ${_v2}" | bc 2>/dev/null && return 0; fi
  return 1
}

# -----------------------------
# Bytes & Storage
# -----------------------------
gsc_pretty_bytes() {
  local _bytes="$1"
  if (( _bytes == 0 )); then echo "0B"; return; fi
  local _units=(B K M G T P E Z Y)
  local _scale=1
  local _i=0
  for ((i=0; i<${#_units[@]}; i++)); do
    if (( _bytes < 1024**($i+1) )); then _scale=$((1024**$i)); break; fi
  done
  local _val=$(echo "scale=1; ${_bytes} / ${_scale}" | bc)
  echo "${_val}${_units[$i]}" | sed 's/\.0//'
}

# Convert human-readable size (e.g. 10G, 50M, 512KB) to KB.
# Raw numbers: >2000000 assumed KB (large KiB value), else assumed MB.
gsc_to_kb() {
    local _size="$1"
    local _value _unit
    if [[ "${_size}" =~ ([0-9.]+)([KMGTPEZY]?B?) ]]; then
        _value="${BASH_REMATCH[1]}"
        _unit="${BASH_REMATCH[2]}"
    elif [[ "${_size}" =~ ([0-9.]+) ]]; then
        _value="${BASH_REMATCH[1]}"
        if (( $(echo "$_value > 2000000" | bc -l) )); then
            _unit="KB"
        else
            _unit="MB"
        fi
    fi
    case "${_unit}" in
        "KB"|"K"|"") echo "$_value" ;;
        "MB"|"M") echo "$((_value * 1024))" ;;
        "GB"|"G") echo "$((_value * 1024 * 1024))" ;;
        "TB"|"T") echo "$((_value * 1024 * 1024 * 1024))" ;;
        *) echo "0" ;;
    esac
}

# -----------------------------
# Date / Time
# -----------------------------
gsc_get_date_format() {
  local _ts="${1:-$(date +%s)}"
  date -u -d "@${_ts}" +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -r "${_ts}" +'%Y-%m-%dT%H:%M:%SZ'
}

# -----------------------------
# Container Port Helpers
# -----------------------------
_gsc_reserved_ports=(9093 9100 8080 9115 9116 9104)
_gsc_excluded_ports=()

gsc_collect_container_ports() {
  _gsc_excluded_ports=("${_gsc_reserved_ports[@]}")
  local _line _tok _hp _runtime

  for _runtime in podman docker; do
    if command -v "${_runtime}" >/dev/null 2>&1; then
      while read -r _line; do
        [[ -z "${_line}" ]] && continue
        local _mappings="${_line//,/ }"
        for _tok in ${_mappings}; do
          if [[ "${_tok}" == *"->"* ]]; then
            _hp="${_tok%%->*}"; _hp="${_hp##*:}"
            _gsc_excluded_ports+=("${_hp}")
          elif [[ "${_tok}" == *"/tcp" ]]; then
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
      if [[ -z "${_seen[${_p}]:-}" ]]; then _uniq+=("${_p}"); _seen["${_p}"]=1; fi
    done
    _gsc_excluded_ports=("${_uniq[@]}")
  fi
}

gsc_port_in_use() {
  local _p="$1" _ep
  for _ep in "${_gsc_excluded_ports[@]:-}"; do [[ "${_p}" -eq "${_ep}" ]] && return 0; done
  if command -v ss >/dev/null 2>&1; then ss -tuln 2>/dev/null | awk 'NR>1 {print $5}' | grep -qE "(:|\\.)${_p}$" && return 0
  elif command -v netstat >/dev/null 2>&1; then netstat -tuln 2>/dev/null | awk 'NR>2 {print $4}' | grep -qE "(:|\\.)${_p}$" && return 0; fi
  return 1
}

# -----------------------------
# Space estimation helpers
# -----------------------------
gsc_estimate_uncompressed_size() {
  local _archive="$1"
  [[ "${_archive}" == *.xz ]] && xz --robot -l -- "${_archive}" 2>/dev/null | awk '$1=="totals"{print $5}' | tail -n1 || return 1
}

gsc_check_extract_space() {
  local _archive="$1" _target_dir="$2" _warn_pct="${3:-10}" _fail_pct="${4:-5}"
  local _size=$(gsc_estimate_uncompressed_size "${_archive}") || return 0
  local _df_line=$(df -P -B1 -- "${_target_dir}" 2>/dev/null | awk 'NR==2') || return 0
  read -r _dev _total _used _avail _use _mnt <<<"${_df_line}"
  local _free_after=$((_avail - _size))
  if (( _free_after < 0 )); then gsc_log_error "Not enough space"; return 2; fi
  local _pct_after=$(( 100 * _free_after / _total ))
  if (( _pct_after < _fail_pct )); then return 2; elif (( _pct_after < _warn_pct )); then return 0; fi
}

gsc_print_space_estimate() {
  local _archive="$1" _target_dir="$2"
  local _size=$(gsc_estimate_uncompressed_size "${_archive}") || return 1
  local _df_line=$(df -P -B1 -- "${_target_dir}" 2>/dev/null | awk 'NR==2') || return 1
  read -r _dev _total _used _avail _use _mnt <<<"${_df_line}"
  local _pct=$(( 100 * (_avail - _size) / _total ))
  gsc_log_info "Estimate for ${_archive}: size≈$((_size/1048576)) MiB, free_after≈~${_pct}%."
}

# -----------------------------
# Progress tool detection
# -----------------------------
_have_pv=0
_have_progress=0
gsc_detect_progress_tools() {
  _have_pv=0; _have_progress=0
  if command -v pv >/dev/null 2>&1; then _have_pv=1; fi
  if command -v progress >/dev/null 2>&1; then _have_progress=1; fi
}

# -----------------------------
# HCPCS legacy globals + helpers (Restored)
# -----------------------------
_username="admin"; _cluster_name=""; _realm=""; _passwd=""; _dir_name=""; _verbose="false"; _file_name=""; _port_num=""; _debug=${_debug:-0}
setLogFile() { local _f="$1"; [[ "$_f" == *.log ]] || _f="${_f}.log"; _log_file_name="$_f"; }
log()  { printf '%s\n' "$1" > "${_log_file_name}" 2>/dev/null || true; }
loga() { printf '%s\n' "$1" >> "${_log_file_name}" 2>/dev/null || true; }
log2()  { gsc_log_info "$1"; printf '%s\n' "$1" > "${_log_file_name}" 2>/dev/null || true; }
getOptions() {
  local _opt; OPTIND=1
  while getopts "c:u:p:r:d:v:s:w:h:f:n:" _opt; do
    case "${_opt}" in
      c) _cluster_name=${OPTARG} ;; u) _username=${OPTARG} ;; p) _passwd=${OPTARG} ;;
      r) _realm=${OPTARG} ;; d) _dir_name=${OPTARG} ;; v) _verbose="true" ;;
      f) _file_name=${OPTARG} ;; n) _port_num=${OPTARG} ;; h) usage; exit 0 ;;
      *) gsc_log_warn "getOptions: unknown flag -${_opt}"; usage; exit 1 ;;
    esac
  done
}
handleBasicOptions() {
  [[ -z "${_realm}" ]] && _realm="$( [[ "${_username}" == "admin" ]] && echo "local" || echo "openLDAP" )"
  [[ -n "${_cluster_name}" || -n "${_file_name}" ]] || { gsc_log_error "option -c or -f must be specified"; usage; exit 1; }
  [[ -n "${_dir_name}" ]] || _dir_name="supportLogs"
}
createDir() { [[ ! -d "${_dir_name}" ]] && mkdir -p "${_dir_name}" || true; }
hcpcs_json_body_from_file() { local _file="$1"; [[ -r "${_file}" ]] || return 1; sed -n '/^[[:space:]]*[{[]/,$p' "${_file}"; }

# Auto-setup _log_file_name
if [[ -z "${_log_file_name:-}" ]]; then
  _gsc_script_base="$(basename "${0:-gsc_script}")"; _log_file_name="${_gsc_script_base%.*}.log"
fi
if [[ -n "${_log_file_name:-}" && -e "${_log_file_name}" ]]; then
  gsc_rotate_log "${_log_file_name}" 2
fi
