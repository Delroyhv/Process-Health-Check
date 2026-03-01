#!/usr/bin/env bash
#
# gsc_prometheus.sh - Extract a Prometheus snapshot and run it in a container
#
# Unified replacement for:
#   - gsc_container_prometheus.sh
#   - gsc_docker_prometheus.sh
#
# Version: 1.8.31
#

set -euo pipefail
IFS=$'\n\t'

_script_version="1.8.31"

# ---------------------------------------------------------------------------
# Source common library (and core if present)
# ---------------------------------------------------------------------------
_gsc_lib_path="${GSC_LIB_PATH:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gsc_core.sh}"
if [[ ! -r "${_gsc_lib_path}" ]]; then
  echo "ERROR: Unable to read gsc_core.sh at ${_gsc_lib_path}" >&2
  exit 1
fi
# shellcheck disable=SC1090
. "${_gsc_lib_path}"

# ---------------------------------------------------------------------------
# Defaults and globals
# ---------------------------------------------------------------------------
_config_file=""
_base_directory=""
_customer=""
_service_request=""
_snapshot_file=""

_min_port=9090
_max_port=9200

_debug_flag=0
_gsc_debug=0

_space_check_enabled=0
_estimate_only=0

_engine=""           # docker|podman|auto
_replace=0
_keep_container=0     # if 1, do not use --rm

# Prefer fully-qualified image name to avoid podman short-name resolution issues
_image="docker.io/prom/prometheus:latest"

: "${GSC_PROM_LOG_DIR:=/var/log/gsc_prometheus}"
_log_dir="${GSC_PROM_LOG_DIR}/v${_script_version}"
_last_used_port_file="${_log_dir}/last_used_port.txt"
_last_used_port=9090

_exclude_ports_cfg=""
_exclude_ports_cli=()

_usage() {
  cat <<EOU
gsc_prometheus.sh - Extract a Prometheus snapshot and run it in Docker/Podman

Version: ${_script_version}

Usage:
  sudo gsc_prometheus.sh [options]

Required (via CLI or config file):
  -c, --customer NAME              Customer name
  -s, --service-request SR         Service request / case number
  -f, --snapshot-file PATH         Path to Prometheus snapshot .tar.xz
  -b, --base-directory PATH        Base directory for instances

Optional:
  -C, --config-file PATH           Config file (key=value)
      --engine auto|docker|podman  Container engine (default: auto)
      --image IMAGE                Prometheus image (default: ${_image})
      --replace                    Replace existing container with same name
      --keep-container             Do not run container with --rm
      --min-port N                 Minimum port (default: ${_min_port})
      --max-port N                 Maximum port (default: ${_max_port})
      --exclude-port N             Additional port(s) to exclude (repeatable)
      --debug                      Enable verbose logging
      -e, --estimate               Enable pre-extract space check
      --estimate-only              Only run estimate (no extract / container)
      --no-space-check             Disable free-space safety check
      --no-color                   Disable ANSI color output
      --version                    Show version
  -h, --help                       Show help

Notes:
  - Ports are selected automatically and skip:
      * reserved exporter ports: 9093, 9100, 8080, 9115, 9116, 9104
      * ports mapped by running containers
      * extra excluded ports from config/CLI
EOU
}

_read_config() {
  [[ -n "${_config_file}" && -f "${_config_file}" ]] || return 0

  while IFS= read -r _line; do
    [[ -z "${_line}" || "${_line}" =~ ^# ]] && continue
    case "${_line}" in
      customer=*)        _customer="${_line#*=}" ;;
      service_request=*) _service_request="${_line#*=}" ;;
      service-request=*) _service_request="${_line#*=}" ;;
      snapshot_file=*)   _snapshot_file="${_line#*=}" ;;
      base_directory=*)  _base_directory="${_line#*=}" ;;
      min_port=*)        _min_port="${_line#*=}" ;;
      max_port=*)        _max_port="${_line#*=}" ;;
      last_used_port=*)  _last_used_port="${_line#*=}" ;;
      exclude_ports=*)   _exclude_ports_cfg="${_line#*=}" ;;
      engine=*)          _engine="${_line#*=}" ;;
      image=*)           _image="${_line#*=}" ;;
    esac
  done <"${_config_file}"
}

_build_extra_excluded_ports() {
  local _token
  if [[ -n "${_exclude_ports_cfg}" ]]; then
    for _token in ${_exclude_ports_cfg//,/ }; do
      [[ "${_token}" =~ ^[0-9]+$ ]] && _exclude_ports_cli+=("${_token}")
    done
  fi
}

_init_excluded_ports() {
  gsc_collect_container_ports

  local _p
  for _p in "${_exclude_ports_cli[@]}"; do
    _gsc_excluded_ports+=("${_p}")
    [[ "${_gsc_debug}" -eq 1 ]] && gsc_log_info "Excluding extra port: ${_p}"
  done

  if ((${#_gsc_excluded_ports[@]} > 1)); then
    local -A _seen=()
    local _uniq=()
    for _p in "${_gsc_excluded_ports[@]}"; do
      if [[ -z "${_seen[${_p}]:-}" ]]; then
        _uniq+=("${_p}")
        _seen["${_p}"]=1
      fi
    done
    _gsc_excluded_ports=("${_uniq[@]}")
  fi
}

_choose_free_port() {
  if [[ -f "${_last_used_port_file}" ]]; then
    _last_used_port="$(<"${_last_used_port_file}")"
  fi

  [[ "${_last_used_port}" =~ ^[0-9]+$ ]] || _last_used_port="${_min_port}"
  ((_last_used_port < _min_port)) && _last_used_port="${_min_port}"

  while ((_last_used_port <= _max_port)); do
    if ! gsc_port_in_use "${_last_used_port}"; then
      [[ "${_gsc_debug}" -eq 1 ]] && gsc_log_info "Selected free port: ${_last_used_port}"
      echo "${_last_used_port}"
      return 0
    fi
    [[ "${_gsc_debug}" -eq 1 ]] && gsc_log_info "Port ${_last_used_port} in use, trying next..."
    _last_used_port=$((_last_used_port + 1))
  done

  gsc_die "No free ports available in range ${_min_port}-${_max_port}"
}

_save_last_used_port() {
  mkdir -p "${_log_dir}"
  echo "${_last_used_port}" >"${_last_used_port_file}"
}

_detect_engine() {
  if [[ -n "${_engine}" && "${_engine}" != "auto" ]]; then
    printf '%s\n' "${_engine}"
    return 0
  fi

  if command -v gsc_detect_engine >/dev/null 2>&1; then
    gsc_detect_engine
    return 0
  fi

  gsc_detect_container_runtime
}

_start_prometheus_container() {
  local _port="$1"
  local _data_dir="$2"
  local _prom_dir="$3"

  local _runtime
  _runtime="$(_detect_engine)"

  local _name="gsc_prometheus_${_customer}_${_service_request}_${_port}"

  gsc_log_info "Starting Prometheus in ${_runtime} on port ${_port} for ${_customer}/${_service_request}"

  if [[ "${_replace}" -eq 1 ]]; then
    if command -v gsc_container_rm_if_exists >/dev/null 2>&1; then
      gsc_container_rm_if_exists "${_runtime}" "${_name}"
    else
      "${_runtime}" rm -f "${_name}" >/dev/null 2>&1 || true
    fi
  fi

  local _rm_args=()
  [[ "${_keep_container}" -eq 0 ]] && _rm_args+=("--rm")

  local _extra=()
  if [[ "${_runtime}" == "podman" && "${_replace}" -eq 1 ]]; then
    _extra+=("--replace")
  fi

  "${_runtime}" run -d \
    "${_rm_args[@]}" \
    "${_extra[@]}" \
    --name "${_name}" \
    -p "${_port}:9090" \
    -v "${_data_dir}:/prometheus" \
    -v "${_prom_dir}/prometheus.yml:/etc/prometheus/prometheus.yml:ro" \
    "${_image}"
}

_main() {
  gsc_require_root

  local _arg
  while [[ $# -gt 0 ]]; do
    _arg="$1"
    case "${_arg}" in
      -c|--customer) _customer="$2"; shift 2 ;;
      -s|--service-request|--service_request) _service_request="$2"; shift 2 ;;
      -f|--snapshot-file|--snapshot_file) _snapshot_file="$2"; shift 2 ;;
      -b|--base-directory|--base_directory) _base_directory="$2"; shift 2 ;;
      -C|--config-file|--config_file) _config_file="$2"; shift 2 ;;
      --engine) _engine="$2"; shift 2 ;;
      --image) _image="$2"; shift 2 ;;
      --replace) _replace=1; shift 1 ;;
      --keep-container) _keep_container=1; shift 1 ;;
      --min-port|--min_port) _min_port="$2"; shift 2 ;;
      --max-port|--max_port) _max_port="$2"; shift 2 ;;
      --exclude-port|--exclude_port) _exclude_ports_cli+=("$2"); shift 2 ;;
      -e|--estimate) _space_check_enabled=1; shift 1 ;;
      --estimate-only|--estimate_only) _space_check_enabled=1; _estimate_only=1; shift 1 ;;
      --no-space-check|--no_space_check) _space_check_enabled=0; _estimate_only=0; shift 1 ;;
      --debug) _debug_flag=1; _gsc_debug=1; shift 1 ;;
      --no-color) _gsc_enable_color=0; shift 1 ;;
      --version) echo "${_script_version}"; return 0 ;;
      -h|--help) _usage; return 0 ;;
      --) shift; break ;;
      *) gsc_log_warn "Unknown option: ${_arg}"; _usage; return 1 ;;
    esac
  done

  _read_config
  _build_extra_excluded_ports

  if [[ -z "${_customer}" || -z "${_service_request}" || -z "${_snapshot_file}" || -z "${_base_directory}" ]]; then
    gsc_die "Missing required arguments (customer, service_request, snapshot_file, base_directory)."
  fi
  [[ -f "${_snapshot_file}" ]] || gsc_die "Snapshot file '${_snapshot_file}' does not exist."

  if [[ ! -d "${_base_directory}" ]]; then
    gsc_log_warn "Base directory '${_base_directory}' does not exist. Creating it..."
    mkdir -p "${_base_directory}" || gsc_die "Failed to create base directory '${_base_directory}'."
    gsc_log_ok "Created base directory '${_base_directory}'."
  fi

  if [[ "${_estimate_only}" -eq 0 ]]; then
    _detect_engine >/dev/null 2>&1 || gsc_die "Neither podman nor docker found in PATH."
  fi

  mkdir -p "${_log_dir}"

  local _customer_dir="${_base_directory}/${_customer}/${_service_request}"
  local _data_dir="${_customer_dir}/prom/data"
  local _prom_dir="${_customer_dir}/prom"
  mkdir -p "${_data_dir}" "${_prom_dir}"

  _init_excluded_ports

  local _port
  _port="$(_choose_free_port)"
  _last_used_port="${_port}"

  gsc_log_info "Extracting snapshot '${_snapshot_file}' into ${_data_dir}"

  if [[ "${_space_check_enabled}" -eq 1 ]]; then
    gsc_print_space_estimate "${_snapshot_file}" "${_data_dir}" || true
    gsc_check_extract_space "${_snapshot_file}" "${_data_dir}" || gsc_die "Insufficient space to extract snapshot into ${_data_dir}"
  fi

  if [[ "${_estimate_only}" -eq 1 ]]; then
    gsc_log_info "Estimate-only mode: not extracting snapshot and not starting container."
    return 0
  fi

  if command -v pv >/dev/null 2>&1; then
    pv "${_snapshot_file}" | xz -d -T0 | tar --no-same-owner --no-same-permissions -C "${_data_dir}" --strip-components=1 -xf -
  else
    xz -d -T0 <"${_snapshot_file}" | tar --no-same-owner --no-same-permissions -C "${_data_dir}" --strip-components=1 -xf -
  fi

  cat >"${_prom_dir}/prometheus.yml" <<'EOPROM'
global:
  scrape_interval: 15s
scrape_configs:
  - job_name: 'self'
    static_configs:
      - targets: ['localhost:9090']
EOPROM

  chmod -R 0777 "${_data_dir}" || true
  chown -R 65534:65534 "${_data_dir}" 2>/dev/null || true

  _start_prometheus_container "${_port}" "${_data_dir}" "${_prom_dir}"
  _save_last_used_port

  # Auto-patch healthcheck.conf that lives alongside the snapshot file
  local _hc_conf
  _hc_conf="$(dirname -- "${_snapshot_file}")/healthcheck.conf"
  if [[ -f "${_hc_conf}" ]]; then
    sed -i -E "s/^_prom_port=\"[^\"]*\"/_prom_port=\"${_port}\"/" "${_hc_conf}" 2>/dev/null || true
    gsc_log_info "Updated ${_hc_conf}: _prom_port=${_port}"
  fi

  gsc_log_ok "Prometheus for ${_customer}/${_service_request} started on port ${_port}."
}

_main "$@"
