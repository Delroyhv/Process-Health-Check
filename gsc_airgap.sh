#!/usr/bin/env bash
#
# gsc_airgap.sh - Load and start Prometheus + Grafana on an air-gapped system
#
# Supports four lifecycle modes:
#   --save-images OUTDIR    Pull images on a connected host and export to tar bundle
#   --load-images BUNDLEDIR Import image tars into the container engine (air-gapped host)
#   --start                 Extract psnap, start Prometheus then Grafana
#   --stop                  Stop and remove managed containers
#
# Standards:
#   - Strict mode (set -euo pipefail) via gsc_core.sh
#   - All variables lowercase with _ prefix
#   - All shared functions from gsc_core.sh (logging, engine detect, port helpers)
#   - :z SELinux relabel on all volume mounts (harmless on non-SELinux systems)
#
# Version: 1.0.0
#

set -euo pipefail
IFS=$'\n\t'

_script_version="1.0.0"
_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Source shared library
# ---------------------------------------------------------------------------
_gsc_lib_path="${GSC_LIB_PATH:-${_script_dir}/gsc_core.sh}"
if [[ ! -r "${_gsc_lib_path}" ]]; then
  echo "ERROR: Unable to read gsc_core.sh at ${_gsc_lib_path}" >&2
  exit 1
fi
# shellcheck disable=SC1090
. "${_gsc_lib_path}"

# ---------------------------------------------------------------------------
# Defaults and globals
# ---------------------------------------------------------------------------

# Operational mode set by the first positional flag
_mode=""                      # save-images | load-images | start | stop

# Image names and tags — override with --prom-image / --grafana-image / --prom-tag / --grafana-tag
_prom_image="docker.io/prom/prometheus"
_grafana_image="docker.io/grafana/grafana"
_prom_tag="latest"
_grafana_tag="latest"

# Path to the tar bundle directory used by --save-images and --load-images
_bundle_dir=""

# Prometheus startup parameters (mirrors gsc_prometheus.sh flags)
_customer=""
_service_request=""
_snapshot_file=""
_base_directory=""
_replace=0
_keep_container=0

# Grafana startup parameters
_dashboards=()
_grafana_port="3000"
_admin_password="admin"
_datasource_url=""            # auto-derived from Prometheus port when empty

# Container engine: empty or "auto" triggers gsc_detect_engine
_engine=""

# Port selection bounds for Prometheus (same defaults as gsc_prometheus.sh)
_min_port=9090
_max_port=9599
_exclude_ports_cli=()

# Cleanup options
_cleanup_volumes=0
_override_confirm=""

# Debug / display
_debug_flag=0
_gsc_debug=0

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
_usage() {
  cat <<EOU
gsc_airgap.sh - Load and start Prometheus + Grafana on an air-gapped system

Version: ${_script_version}

Usage:
  sudo gsc_airgap.sh --save-images OUTDIR   [image-opts] [engine-opts]
  sudo gsc_airgap.sh --load-images BUNDLEDIR [engine-opts]
  sudo gsc_airgap.sh --start  -c NAME -s SR -f PSNAP -b BASEDIR [opts]
  sudo gsc_airgap.sh --stop   [cleanup-opts] [engine-opts]

Modes:
  --save-images OUTDIR     Pull Prometheus + Grafana and export to OUTDIR/*.tar
                           (run on a connected host before transporting the bundle)
  --load-images BUNDLEDIR  Load image tars from BUNDLEDIR into the container engine
                           (run on the air-gapped host after bundle transport)
  --start                  Extract the psnap, start Prometheus, then start Grafana
  --stop                   Stop and remove all containers managed by this tool

Prometheus options (required for --start):
  -c, --customer NAME          Customer name
  -s, --service-request SR     Service request / case number
  -f, --snapshot-file PATH     Path to Prometheus snapshot .tar.xz (psnap)
  -b, --base-directory PATH    Base directory for extracted data

Grafana options (optional for --start):
  -D, --dashboard FILE         Dashboard JSON or archive (repeatable; .json/.zip/.tar.gz/.tar.xz)
  -g, --grafana-port PORT      Grafana listen port (default: ${_grafana_port})
  -i, --datasource IP:PORT     Prometheus datasource address (default: auto from prom port)
  --admin-password PASSWORD    Grafana admin password (default: ${_admin_password})

Image options:
  --prom-tag TAG               Prometheus image tag to pull/load (default: ${_prom_tag})
  --grafana-tag TAG            Grafana image tag to pull/load (default: ${_grafana_tag})
  --prom-image IMAGE           Prometheus image name (default: ${_prom_image})
  --grafana-image IMAGE        Grafana image name (default: ${_grafana_image})

Container options:
  --engine auto|docker|podman  Container engine (default: auto)
  --replace                    Remove existing container with the same name before starting
  --keep-container             Do not use --rm; container persists after it stops
  --min-port N                 Lowest port for Prometheus auto-selection (default: ${_min_port})
  --max-port N                 Highest port for Prometheus auto-selection (default: ${_max_port})
  --exclude-port N             Additional port to skip during selection (repeatable)

Cleanup options (for --stop):
  --volume                     Also delete data directories
  --override=y                 Skip confirmation prompts

Other:
  --debug                      Enable verbose diagnostic output
  --no-color                   Disable ANSI colour output
  --version                    Print version and exit
  -h, --help                   Print this help and exit

Examples:
  # On the connected host — bundle images for transport
  sudo gsc_airgap.sh --save-images /mnt/usb/airgap_bundle

  # On the air-gapped host — load the bundle
  sudo gsc_airgap.sh --load-images /mnt/usb/airgap_bundle

  # Start both containers
  sudo gsc_airgap.sh --start \\
      -c ACME -s 05304447 \\
      -f /data/psnap_2026-Jul-04.tar.xz \\
      -b /opt/prom_instances \\
      -D /data/dashboards.zip

  # Stop and clean up
  sudo gsc_airgap.sh --stop --override=y
EOU
}

# ---------------------------------------------------------------------------
# Image name helpers
# ---------------------------------------------------------------------------

# Derive a safe tar filename from image name + tag.
# docker.io/prom/prometheus + latest  ->  prometheus_latest.tar
# docker.io/grafana/grafana + 10.0.0  ->  grafana_10.0.0.tar
_image_to_filename() {
  local _img="$1"
  local _tag="$2"
  # Strip everything up to and including the last slash (registry + org)
  local _short="${_img##*/}"
  # Replace any remaining path characters with underscores
  _short=$(printf '%s' "${_short}" | tr '/.' '_')
  printf '%s_%s.tar\n' "${_short}" "${_tag}"
}

# Return the full image reference (name:tag) for Prometheus
_prom_image_ref() { printf '%s:%s\n' "${_prom_image}" "${_prom_tag}"; }

# Return the full image reference (name:tag) for Grafana
_grafana_image_ref() { printf '%s:%s\n' "${_grafana_image}" "${_grafana_tag}"; }

# Return 0 if the image is already present locally, 1 otherwise
_image_exists() {
  local _eng="$1"
  local _ref="$2"
  "${_eng}" image inspect "${_ref}" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Mode: --save-images
# Pull both images on a connected host and export them to tar files in OUTDIR.
# Writes airgap_manifest.txt so --load-images knows the filenames and can
# verify image digests after transport.
# ---------------------------------------------------------------------------
_save_images() {
  local _runtime
  _runtime="$(_resolve_engine)"

  [[ -n "${_bundle_dir}" ]] || gsc_die "--save-images requires a directory path argument."
  mkdir -p "${_bundle_dir}"

  local _prom_ref _grafana_ref
  _prom_ref="$(_prom_image_ref)"
  _grafana_ref="$(_grafana_image_ref)"

  local _prom_file _grafana_file
  _prom_file="${_bundle_dir}/$(_image_to_filename "${_prom_image}" "${_prom_tag}")"
  _grafana_file="${_bundle_dir}/$(_image_to_filename "${_grafana_image}" "${_grafana_tag}")"

  gsc_log_info "Pulling Prometheus image: ${_prom_ref}"
  "${_runtime}" pull "${_prom_ref}"

  gsc_log_info "Pulling Grafana image: ${_grafana_ref}"
  "${_runtime}" pull "${_grafana_ref}"

  gsc_log_info "Saving Prometheus → ${_prom_file}"
  "${_runtime}" save -o "${_prom_file}" "${_prom_ref}"

  gsc_log_info "Saving Grafana → ${_grafana_file}"
  "${_runtime}" save -o "${_grafana_file}" "${_grafana_ref}"

  # Capture digests for integrity verification on the receiving host
  local _prom_digest _grafana_digest
  _prom_digest=$("${_runtime}" inspect \
    --format '{{index .RepoDigests 0}}' "${_prom_ref}" 2>/dev/null || echo "unknown")
  _grafana_digest=$("${_runtime}" inspect \
    --format '{{index .RepoDigests 0}}' "${_grafana_ref}" 2>/dev/null || echo "unknown")

  # Write manifest — parsed by _load_images to locate tar files and verify images
  local _manifest="${_bundle_dir}/airgap_manifest.txt"
  cat >"${_manifest}" <<EOMAN
# gsc_airgap image bundle manifest
# Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
# Engine: ${_runtime}
prometheus_image=${_prom_ref}
prometheus_file=$(basename "${_prom_file}")
prometheus_digest=${_prom_digest}
grafana_image=${_grafana_ref}
grafana_file=$(basename "${_grafana_file}")
grafana_digest=${_grafana_digest}
EOMAN

  gsc_log_ok "Bundle saved to: ${_bundle_dir}"
  gsc_log_info "  $(basename "${_prom_file}")"
  gsc_log_info "  $(basename "${_grafana_file}")"
  gsc_log_info "  airgap_manifest.txt"
  gsc_log_info "Transport the bundle directory to the air-gapped host, then run:"
  gsc_log_info "  sudo gsc_airgap.sh --load-images <BUNDLEDIR>"
}

# ---------------------------------------------------------------------------
# Mode: --load-images
# Read airgap_manifest.txt from the bundle directory and load each tar into
# the container engine.  Idempotent: skips images that are already present.
# ---------------------------------------------------------------------------
_load_images() {
  local _runtime
  _runtime="$(_resolve_engine)"

  [[ -n "${_bundle_dir}" ]] || gsc_die "--load-images requires a directory path argument."

  local _manifest="${_bundle_dir}/airgap_manifest.txt"
  [[ -f "${_manifest}" ]] || \
    gsc_die "Manifest not found: ${_manifest}. Was --save-images run on the source host?"

  # Parse the manifest — only the keys we need
  local _prom_img="" _prom_file="" _grafana_img="" _grafana_file=""
  local _line
  while IFS= read -r _line; do
    [[ -z "${_line}" || "${_line}" =~ ^# ]] && continue
    case "${_line}" in
      prometheus_image=*)  _prom_img="${_line#*=}" ;;
      prometheus_file=*)   _prom_file="${_bundle_dir}/${_line#*=}" ;;
      grafana_image=*)     _grafana_img="${_line#*=}" ;;
      grafana_file=*)      _grafana_file="${_bundle_dir}/${_line#*=}" ;;
    esac
  done <"${_manifest}"

  [[ -n "${_prom_img}"     ]] || gsc_die "prometheus_image missing from manifest"
  [[ -n "${_prom_file}"    ]] || gsc_die "prometheus_file missing from manifest"
  [[ -n "${_grafana_img}"  ]] || gsc_die "grafana_image missing from manifest"
  [[ -n "${_grafana_file}" ]] || gsc_die "grafana_file missing from manifest"

  # Load Prometheus — skip if already present (idempotent)
  if _image_exists "${_runtime}" "${_prom_img}"; then
    gsc_log_info "Prometheus image already present: ${_prom_img} — skipping load"
  else
    [[ -f "${_prom_file}" ]] || gsc_die "Prometheus tar not found: ${_prom_file}"
    gsc_log_info "Loading Prometheus image from $(basename "${_prom_file}")"
    "${_runtime}" load -i "${_prom_file}"
    gsc_log_ok "Loaded: ${_prom_img}"
  fi

  # Load Grafana — skip if already present (idempotent)
  if _image_exists "${_runtime}" "${_grafana_img}"; then
    gsc_log_info "Grafana image already present: ${_grafana_img} — skipping load"
  else
    [[ -f "${_grafana_file}" ]] || gsc_die "Grafana tar not found: ${_grafana_file}"
    gsc_log_info "Loading Grafana image from $(basename "${_grafana_file}")"
    "${_runtime}" load -i "${_grafana_file}"
    gsc_log_ok "Loaded: ${_grafana_img}"
  fi

  gsc_log_ok "All images loaded. Start both services with:"
  gsc_log_info "  sudo gsc_airgap.sh --start -c NAME -s SR -f PSNAP -b BASEDIR"
}

# ---------------------------------------------------------------------------
# Port selection — mirrors gsc_prometheus.sh logic
# ---------------------------------------------------------------------------

# Initialise the excluded-port list from running containers plus any CLI overrides
_init_excluded_ports() {
  gsc_collect_container_ports
  local _p
  for _p in "${_exclude_ports_cli[@]+"${_exclude_ports_cli[@]}"}"; do
    _gsc_excluded_ports+=("${_p}")
  done
}

# Pick a random free port in [_min_port, _max_port]; falls back to sequential scan
_choose_free_port() {
  local _max_attempts=100
  local _attempt=0
  local _candidate

  # Seed RANDOM with PID for better distribution across concurrent calls
  RANDOM=$(( $$ + RANDOM ))

  while (( _attempt < _max_attempts )); do
    _candidate=$(( RANDOM % (_max_port - _min_port + 1) + _min_port ))
    if ! gsc_port_in_use "${_candidate}"; then
      [[ "${_gsc_debug}" -eq 1 ]] && gsc_log_info "Selected random free port: ${_candidate}"
      echo "${_candidate}"
      return 0
    fi
    (( _attempt++ )) || true
  done

  # Fallback: sequential scan from _min_port
  local _p
  for (( _p = _min_port; _p <= _max_port; _p++ )); do
    if ! gsc_port_in_use "${_p}"; then
      echo "${_p}"
      return 0
    fi
  done

  gsc_die "No free ports available in range ${_min_port}-${_max_port}."
}

# ---------------------------------------------------------------------------
# Start: Prometheus container
# Extracts the psnap, writes a minimal prometheus.yml, and runs the container.
# Prints the selected port to stdout so the caller can pass it to Grafana.
# ---------------------------------------------------------------------------
_start_prometheus() {
  local _runtime="$1"
  local _port
  _port="$(_choose_free_port)"

  local _name="gsc_prometheus_${_customer}_${_service_request}_${_port}"
  local _customer_dir="${_base_directory}/${_customer}/${_service_request}"
  local _data_dir="${_customer_dir}/prom/data"
  local _prom_dir="${_customer_dir}/prom"
  mkdir -p "${_data_dir}" "${_prom_dir}"

  # Extract the snapshot archive; use pv for progress if available
  gsc_log_info "Extracting snapshot '${_snapshot_file}' → ${_data_dir}"
  if command -v pv >/dev/null 2>&1; then
    pv "${_snapshot_file}" | xz -d -T0 \
      | tar --no-same-owner --no-same-permissions -C "${_data_dir}" --strip-components=1 -xf -
  else
    xz -d -T0 <"${_snapshot_file}" \
      | tar --no-same-owner --no-same-permissions -C "${_data_dir}" --strip-components=1 -xf -
  fi

  # Minimal Prometheus configuration — only a self-scrape job is needed
  cat >"${_prom_dir}/prometheus.yml" <<'EOPROM'
global:
  scrape_interval: 15s
scrape_configs:
  - job_name: 'self'
    static_configs:
      - targets: ['localhost:9090']
EOPROM

  # Prometheus runs as UID 65534 (nobody); set permissions so it can write WAL
  gsc_log_info "Setting data directory permissions..."
  chmod -R 0777 "${_data_dir}" || true
  chown -R 65534:65534 "${_data_dir}" 2>/dev/null || true

  if [[ "${_replace}" -eq 1 ]]; then
    gsc_container_rm_if_exists "${_runtime}" "${_name}"
  fi

  local _rm_args=()
  [[ "${_keep_container}" -eq 0 ]] && _rm_args+=("--rm")

  # podman --replace flag replaces an existing container atomically
  local _extra=()
  if [[ "${_runtime}" == "podman" && "${_replace}" -eq 1 ]]; then
    _extra+=("--replace")
  fi

  local _prom_ref
  _prom_ref="$(_prom_image_ref)"
  gsc_log_info "Starting Prometheus container '${_name}' on port ${_port}"

  # :z SELinux shared-relabel; harmless on non-SELinux systems (v1.2.70 fix)
  "${_runtime}" run -d \
    "${_rm_args[@]+"${_rm_args[@]}"}" \
    "${_extra[@]+"${_extra[@]}"}" \
    --name "${_name}" \
    -p "${_port}:9090" \
    -v "${_data_dir}:/prometheus:z" \
    -v "${_prom_dir}/prometheus.yml:/etc/prometheus/prometheus.yml:ro,z" \
    "${_prom_ref}"

  # Auto-patch healthcheck.conf that lives alongside the snapshot file
  local _hc_conf
  _hc_conf="$(dirname -- "${_snapshot_file}")/healthcheck.conf"
  if [[ -f "${_hc_conf}" ]]; then
    sed -i -E "s/^_prom_port=\"[^\"]*\"/_prom_port=\"${_port}\"/" "${_hc_conf}" 2>/dev/null || true
    gsc_log_info "Updated ${_hc_conf}: _prom_port=${_port}"
  fi

  gsc_log_ok "Prometheus started on port ${_port} (container: ${_name})"

  # Print selected port to stdout — captured by _do_start and passed to Grafana
  echo "${_port}"
}

# ---------------------------------------------------------------------------
# Start: Grafana container
# Provisions dashboards and datasource YAML then starts the container.
# ---------------------------------------------------------------------------
_start_grafana() {
  local _runtime="$1"
  local _prom_port="$2"

  # Derive datasource URL from Prometheus port when not explicitly supplied
  if [[ -z "${_datasource_url}" ]]; then
    _datasource_url="http://localhost:${_prom_port}"
  fi

  local _name="gsc_grafana_${_customer}_${_service_request}"
  local _work_dir="${_base_directory}/${_customer}/${_service_request}/grafana"
  local _dash_dir="${_work_dir}/dashboards"
  local _prov_dir="${_work_dir}/provisioning"

  mkdir -p "${_dash_dir}" "${_prov_dir}/dashboards" "${_prov_dir}/datasources"

  # Copy or extract each dashboard file into the dashboard directory
  if [[ ${#_dashboards[@]} -gt 0 ]]; then
    local _file
    for _file in "${_dashboards[@]}"; do
      case "${_file}" in
        *.json)   cp "${_file}" "${_dash_dir}/" ;;
        *.zip)    unzip -o "${_file}" -d "${_dash_dir}" >/dev/null ;;
        *.tar.gz) tar -xzf "${_file}" -C "${_dash_dir}" ;;
        *.tar.xz) tar -xJf "${_file}" -C "${_dash_dir}" ;;
        *)        gsc_die "Unsupported dashboard format: ${_file}" ;;
      esac
    done
  fi

  # Grafana provisioning: datasource pointing at Prometheus
  cat >"${_prov_dir}/datasources/datasource.yaml" <<EODS
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: ${_datasource_url}
    isDefault: true
    editable: true
EODS

  # Grafana provisioning: dashboard file provider
  cat >"${_prov_dir}/dashboards/dashboards.yaml" <<'EODB'
apiVersion: 1
providers:
  - name: 'hcp-dashboards'
    orgId: 1
    folder: 'HCP Dashboards'
    type: file
    disableDeletion: false
    editable: true
    options:
      path: /var/lib/grafana/dashboards
EODB

  if [[ "${_replace}" -eq 1 ]]; then
    gsc_container_rm_if_exists "${_runtime}" "${_name}"
  fi

  local _rm_args=()
  [[ "${_keep_container}" -eq 0 ]] && _rm_args+=("--rm")

  local _extra=()
  if [[ "${_runtime}" == "podman" && "${_replace}" -eq 1 ]]; then
    _extra+=("--replace")
  fi

  local _grafana_ref
  _grafana_ref="$(_grafana_image_ref)"
  gsc_log_info "Starting Grafana container '${_name}' on port ${_grafana_port}"

  # :z SELinux shared-relabel on all volume mounts
  "${_runtime}" run -d \
    "${_rm_args[@]+"${_rm_args[@]}"}" \
    "${_extra[@]+"${_extra[@]}"}" \
    --name "${_name}" \
    -p "${_grafana_port}:3000" \
    -v "${_dash_dir}:/var/lib/grafana/dashboards:z" \
    -v "${_prov_dir}/dashboards:/etc/grafana/provisioning/dashboards:z" \
    -v "${_prov_dir}/datasources:/etc/grafana/provisioning/datasources:z" \
    -e GF_SECURITY_ADMIN_USER=admin \
    -e "GF_SECURITY_ADMIN_PASSWORD=${_admin_password}" \
    "${_grafana_ref}"

  gsc_log_ok "Grafana started on port ${_grafana_port} (container: ${_name})"
  gsc_log_ok "Access Grafana at: http://localhost:${_grafana_port}  (admin / ${_admin_password})"
  gsc_log_info "Datasource configured: ${_datasource_url}"
}

# ---------------------------------------------------------------------------
# Mode: --start — validate args, start Prometheus then Grafana
# ---------------------------------------------------------------------------
_do_start() {
  # Validate required Prometheus arguments
  if [[ -z "${_customer}" || -z "${_service_request}" \
     || -z "${_snapshot_file}" || -z "${_base_directory}" ]]; then
    gsc_die "Missing required arguments for --start: -c CUSTOMER -s SR -f SNAPSHOT -b BASEDIR"
  fi
  [[ -f "${_snapshot_file}" ]] || gsc_die "Snapshot file not found: ${_snapshot_file}"

  if [[ ! -d "${_base_directory}" ]]; then
    gsc_log_warn "Base directory '${_base_directory}' does not exist — creating it"
    mkdir -p "${_base_directory}" || gsc_die "Cannot create base directory: ${_base_directory}"
  fi

  local _runtime
  _runtime="$(_resolve_engine)"

  # Verify images are present; Prometheus is mandatory, Grafana is optional
  local _prom_ref _grafana_ref
  _prom_ref="$(_prom_image_ref)"
  _grafana_ref="$(_grafana_image_ref)"

  if ! _image_exists "${_runtime}" "${_prom_ref}"; then
    gsc_die "Prometheus image '${_prom_ref}' not found locally. Run --load-images first."
  fi

  local _start_grafana_flag=1
  if ! _image_exists "${_runtime}" "${_grafana_ref}"; then
    gsc_log_warn "Grafana image '${_grafana_ref}' not found locally — Grafana will not be started."
    gsc_log_warn "Run --load-images first to enable Grafana startup."
    _start_grafana_flag=0
  fi

  _init_excluded_ports

  # Start Prometheus and capture the allocated port
  local _prom_port
  _prom_port="$(_start_prometheus "${_runtime}")"

  if [[ "${_start_grafana_flag}" -eq 1 ]]; then
    _start_grafana "${_runtime}" "${_prom_port}"
  fi
}

# ---------------------------------------------------------------------------
# Mode: --stop — stop and remove managed containers
# ---------------------------------------------------------------------------
_do_stop() {
  local _runtime
  _runtime="$(_resolve_engine)"

  # Stop all Prometheus containers started by this tool (pattern: gsc_prometheus_*)
  gsc_container_cleanup \
    "${_runtime}" "^gsc_prometheus_" \
    "${_override_confirm}" "${_cleanup_volumes}" "${_base_directory:-}"

  # Stop all Grafana containers started by this tool (pattern: gsc_grafana_*)
  gsc_container_cleanup \
    "${_runtime}" "^gsc_grafana_" \
    "${_override_confirm}" "${_cleanup_volumes}" ""
}

# ---------------------------------------------------------------------------
# Engine resolution — honours --engine flag or falls back to gsc_detect_engine
# ---------------------------------------------------------------------------
_resolve_engine() {
  if [[ -n "${_engine}" && "${_engine}" != "auto" ]]; then
    printf '%s\n' "${_engine}"
    return 0
  fi
  gsc_detect_engine || gsc_die "No container engine found — install docker or podman first."
}

# ---------------------------------------------------------------------------
# Argument parsing and entry point
# ---------------------------------------------------------------------------
_main() {
  gsc_require_root

  while [[ $# -gt 0 ]]; do
    case "$1" in
      # Mode flags — consume their directory argument where required
      --save-images)        _mode="save-images"; _bundle_dir="${2:-}"; shift 2 ;;
      --load-images)        _mode="load-images"; _bundle_dir="${2:-}"; shift 2 ;;
      --start)              _mode="start"; shift ;;
      --stop|--cleanup)     _mode="stop"; shift ;;

      # Prometheus startup args
      -c|--customer)        _customer="$2"; shift 2 ;;
      -s|--service-request) _service_request="$2"; shift 2 ;;
      -f|--snapshot-file)   _snapshot_file="$2"; shift 2 ;;
      -b|--base-directory)  _base_directory="$2"; shift 2 ;;
      --replace)            _replace=1; shift ;;
      --keep-container)     _keep_container=1; shift ;;
      --min-port)           _min_port="$2"; shift 2 ;;
      --max-port)           _max_port="$2"; shift 2 ;;
      --exclude-port)       _exclude_ports_cli+=("$2"); shift 2 ;;

      # Grafana startup args
      -D|--dashboard)       _dashboards+=("$2"); shift 2 ;;
      -g|--grafana-port)    _grafana_port="$2"; shift 2 ;;
      -i|--datasource)      _datasource_url="http://$2"; shift 2 ;;
      --admin-password)     _admin_password="$2"; shift 2 ;;

      # Image configuration
      --prom-tag)           _prom_tag="$2"; shift 2 ;;
      --grafana-tag)        _grafana_tag="$2"; shift 2 ;;
      --prom-image)         _prom_image="$2"; shift 2 ;;
      --grafana-image)      _grafana_image="$2"; shift 2 ;;

      # Container engine
      --engine)             _engine="$2"; shift 2 ;;

      # Cleanup options
      --volume)             _cleanup_volumes=1; shift ;;
      --override=y)         _override_confirm="y"; shift ;;

      # Misc
      --debug)              _debug_flag=1; _gsc_debug=1; shift ;;
      --no-color)           _gsc_enable_color=0; shift ;;
      --version)            echo "${_script_version}"; return 0 ;;
      -h|--help)            _usage; return 0 ;;
      --)                   shift; break ;;
      *)                    gsc_log_warn "Unknown option: $1"; _usage; return 1 ;;
    esac
  done

  # Sanitize names used in container names and directory paths
  if [[ -n "${_customer}" ]]; then
    _customer="$(gsc_sanitize_name "${_customer}")"
  fi
  if [[ -n "${_service_request}" ]]; then
    _service_request="$(gsc_sanitize_name "${_service_request}")"
  fi

  case "${_mode}" in
    save-images) _save_images ;;
    load-images) _load_images ;;
    start)       _do_start ;;
    stop)        _do_stop ;;
    "")
      gsc_log_error "No mode specified."
      _usage
      return 1
      ;;
    *) gsc_die "Unknown mode: ${_mode}" ;;
  esac
}

_main "$@"
