#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
# -----------------------------------------------------------------------------
# Script: gsc_grafana.sh
# Description: Sets up a Grafana container with specified dashboards using Docker or Podman.
#              Supports dashboard files, directories, URLs, git repositories, and archives.
# Author: GSC
# -----------------------------------------------------------------------------

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${_script_dir}/gsc_core.sh"

# -------------------------------
# Configuration and defaults
# -------------------------------
_container_engine=""
_dashboards=()
_url=""
_git_repo=""
_datasource_url="http://127.0.0.1:9090"
_grafana_port="3000"
_admin_password="admin"
_update_dashboards=0
_query_mode=0
_cleanup_mode=0
_cleanup_volumes=0
_increment_mode=0
_override_confirm=""
_script_name=$(basename "$0")
_dashboard_dir="dashboards"
_provisioning_dir="provisioning"
_customer="unknown"
_sr_number="unknown"
_container_name=""   # resolved after parse_args

# -------------------------------
# Helper: Print usage
# -------------------------------
print_usage() {
    local _exit_code="${1:-1}"
    cat <<EOF
Usage: $_script_name [-p|--podman] [-d|--docker] -D|--dashboard [file|dir ...] [options]

Core Options:
  -p, --podman                       Use Podman as the container engine
  -d, --docker                       Use Docker as the container engine
  -D, --dashboard FILE|DIR           Add one or more dashboard JSON files, directories, or archives
  -f FILE                            Alias for -D (for compatibility with healthcheck suite)
  -c, --customer NAME                Specify the customer name (for organizational purposes)
  -s, --sr-number SR_NUMBER          Specify the Service Request (SR) number
  --url URL                          Download dashboard archive or JSON from URL
  --git URL                          Clone a Git repository containing dashboard JSON files

Additional Options:
  -i, --input IP:PORT,
  --prometheus-data-source IP:PORT   Specify the Prometheus datasource IP and port (e.g., 172.22.20.26:9090)
  -g, --grafana-port PORT            Specify the Grafana port (default: 3000)
  --admin-password PASSWORD          Specify the Grafana admin password (default: admin)
  --update                           Update existing dashboards without clearing the directory
  --query                            Scan for running Prometheus containers and healthcheck.conf to set the datasource
  --cleanup                          Stop and remove the Grafana container
  --increment                        Auto-increment container name if one already exists
  --volume                           Delete dashboards and provisioning directories during cleanup (requires --cleanup)
  --override=y                       Skip confirmation prompts for cleanup

  Example:
    sudo $_script_name --docker -D dashboard1.json dashboards.zip
    sudo $_script_name --podman --prometheus-data-source 172.22.20.26:9090 --grafana-port 3001 --update
    sudo $_script_name --podman --query
    sudo $_script_name --docker --cleanup --override=y
    sudo $_script_name --docker -D DashBoards --increment
EOF
    exit "${_exit_code}"
}

# -------------------------------
# Helper: Query Prometheus Sources
# -------------------------------
query_prometheus_sources() {
    local -a _found_sources=()
    local _hc_file="healthcheck.conf"

    gsc_log_info "Scanning for Prometheus data sources..."

    if [[ -f "$_hc_file" ]]; then
        local _hc_port
        _hc_port=$(grep -E "^_prom_port=" "$_hc_file" | cut -d'"' -f2)
        if [[ -n "$_hc_port" ]]; then
            _found_sources+=("healthcheck.conf (Port: $_hc_port)")
        fi
    fi

    local _runtime
    for _runtime in podman docker; do
        if command -v "$_runtime" >/dev/null 2>&1; then
            local _container_info
            _container_info=$("$_runtime" ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | grep "9090" || true)

            while IFS= read -r _line; do
                [[ -z "$_line" ]] && continue
                local _name="${_line%% *}"
                local _ports="${_line#* }"
                local _hp
                if [[ "$_ports" =~ :([0-9]+)-\>9090 ]]; then
                    _hp="${BASH_REMATCH[1]}"
                    _found_sources+=("Container: $_name (Port: $_hp)")
                fi
            done <<< "$_container_info"
        fi
    done

    if [[ ${#_found_sources[@]} -eq 0 ]]; then
        gsc_log_warn "No Prometheus sources found in containers or healthcheck.conf."
        return 0
    fi

    gsc_log_info "Found Prometheus sources:"
    for i in "${!_found_sources[@]}"; do
        printf "  [%d] %s\n" "$i" "${_found_sources[$i]}"
    done

    local _choice
    read -rp "Select a source [0-$((${#_found_sources[@]}-1))]: " _choice
    if [[ ! "$_choice" =~ ^[0-9]+$ ]] || [[ "$_choice" -lt 0 ]] || [[ "$_choice" -ge ${#_found_sources[@]} ]]; then
        gsc_log_warn "Invalid selection. Using default data source."
        return 0
    fi

    local _selected_port
    _selected_port=$(echo "${_found_sources[$_choice]}" | grep -oE "Port: [0-9]+" | cut -d' ' -f2)

    local _selected_ip
    read -rp "Enter Prometheus IP address [default: 127.0.0.1]: " _selected_ip
    _selected_ip=${_selected_ip:-127.0.0.1}

    _datasource_url="http://$_selected_ip:$_selected_port"
    gsc_log_ok "Datasource set to: $_datasource_url"
}

# -------------------------------
# Helper: Stop/remove Grafana containers and optionally delete data dirs
# -------------------------------
cleanup_grafana() {
    local _runtime="${_container_engine:-}"
    [[ -z "$_runtime" ]] && { command -v podman >/dev/null 2>&1 && _runtime="podman" || _runtime="docker"; }

    local _containers
    if [[ -n "${_container_name:-}" ]]; then
        _containers=$("${_runtime}" ps -a --format '{{.Names}}' | grep -E "^${_container_name}$" || true)
    else
        _containers=$("${_runtime}" ps -a --format '{{.Names}}' | grep -E "^gsc_grafana_" || true)
    fi

    if [[ -z "${_containers}" && "${_cleanup_volumes}" -eq 0 ]]; then
        gsc_log_info "No Grafana containers found."
        return 0
    fi

    if [[ "${_override_confirm}" != "y" ]]; then
        if [[ -n "${_containers}" ]]; then
            echo "WARNING: This will stop and remove the following containers:"
            echo "${_containers}"
        fi
        [[ "${_cleanup_volumes}" -eq 1 ]] && echo "And delete: ${_dashboard_dir}/ ${_provisioning_dir}/"
        local _ans
        read -rp "Are you sure? (y/N): " _ans
        [[ "${_ans,,}" != "y" ]] && gsc_die "Cleanup cancelled."
    fi

    local _name
    for _name in ${_containers}; do
        gsc_log_info "Stopping and removing container: ${_name}"
        "${_runtime}" stop "${_name}" >/dev/null 2>&1 || true
        "${_runtime}" rm -f "${_name}" >/dev/null 2>&1 || true
    done

    if [[ "${_cleanup_volumes}" -eq 1 ]]; then
        for _dir in "${_dashboard_dir}" "${_provisioning_dir}"; do
            if [[ -d "${_dir}" ]]; then
                rm -rf "${_dir}"
                gsc_log_info "Deleted: ${_dir}"
            fi
        done
    fi

    gsc_log_ok "Cleanup complete."
}

# -------------------------------
# Validate dashboard inputs (files or directories)
# -------------------------------
validate_dashboards() {
    for _file in "${_dashboards[@]}"; do
        if [[ ! -f "$_file" && ! -d "$_file" ]]; then
            gsc_log_error "Dashboard path not found: $_file"; exit 1
        fi
    done
}

# -------------------------------
# Extract supported archives
# -------------------------------
extract_archive() {
    local _archive="$1"
    mkdir -p "$_dashboard_dir"
    case "$_archive" in
        *.zip)    gsc_require unzip; unzip -o "$_archive" -d "$_dashboard_dir" ;;
        *.tar.gz) tar -xzf "$_archive" -C "$_dashboard_dir" ;;
        *.tar.xz) tar -xJf "$_archive" -C "$_dashboard_dir" ;;
        *) gsc_log_error "Unsupported archive format: $_archive"; exit 1 ;;
    esac
}

# -------------------------------
# Ingest a dashboard directory
# -------------------------------
ingest_dashboard_dir() {
    local _dir="$1"
    local -a _files=()
    local -a _jsons=()
    local -a _archives=()

    gsc_log_info "Ingesting dashboard directory: ${_dir}"

    mapfile -t _files < <(find "$_dir" -type f | sort)
    if [[ ${#_files[@]} -eq 0 ]]; then
        gsc_log_error "Dashboard directory is empty: $_dir"
        exit 1
    fi

    mapfile -t _jsons < <(find "$_dir" -type f -name '*.json' | sort)
    mapfile -t _archives < <(find "$_dir" -type f \( -name '*.zip' -o -name '*.tar.gz' -o -name '*.tar.xz' \) | sort)

    if [[ ${#_jsons[@]} -eq 0 && ${#_archives[@]} -eq 0 ]]; then
        gsc_log_error "Directory contains files, but no dashboard JSON or archives were found: $_dir"
        exit 1
    fi

    if [[ ${#_jsons[@]} -gt 0 ]]; then
        for _jf in "${_jsons[@]}"; do
            local _dest="${_dashboard_dir}/$(basename "$_jf")"
            [[ "$_jf" == "$_dest" ]] && continue
            cp "$_jf" "$_dashboard_dir/"
        done
    fi

    if [[ ${#_archives[@]} -gt 0 ]]; then
        for _af in "${_archives[@]}"; do
            extract_archive "$_af"
        done
    fi
}

resolve_container_name() {
    local _runtime="${_container_engine:-}"
    local _base="gsc_grafana_${_customer}_${_sr_number}"
    local _name="${_base}"
    local _suffix=2

    [[ -z "$_runtime" ]] && { command -v podman >/dev/null 2>&1 && _runtime="podman" || _runtime="docker"; }

    if [[ "${_increment_mode}" -eq 1 ]]; then
        while "${_runtime}" ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "${_name}"; do
            _name="${_base}_${_suffix}"
            ((_suffix++))
        done
    fi

    printf '%s\n' "${_name}"
}

# -------------------------------
# Parse command-line arguments
# -------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--podman) _container_engine="podman"; shift ;;
            -d|--docker) _container_engine="docker"; shift ;;
            -D|--dashboard|-f)
                shift
                while [[ $# -gt 0 && ! "$1" =~ ^- ]]; do
                    _dashboards+=("$1")
                    shift
                done
                ;;
            -c|--customer)
                shift; _customer=$(gsc_sanitize_name "$1"); shift ;;
            -s|--sr-number)
                shift; _sr_number=$(gsc_sanitize_name "$1"); shift ;;
            --url)
                shift; _url="$1"; shift ;;
            --git)
                shift; _git_repo="$1"; shift ;;
            -i|--input|--prometheus-data-source)
                shift; _datasource_url="http://$1"; shift ;;
            -g|--grafana-port)
                shift; _grafana_port="$1"; shift ;;
            --admin-password)
                shift; _admin_password="$1"; shift ;;
            --update)
                _update_dashboards=1; shift ;;
            --query)
                _query_mode=1; shift ;;
            --cleanup)
                _cleanup_mode=1; shift ;;
            --increment)
                _increment_mode=1; shift ;;
            --volume)
                _cleanup_volumes=1; shift ;;
            --override=y)
                _override_confirm="y"; shift ;;
            -h|--help)
                print_usage 0 ;;
            -*) gsc_log_error "Unknown option: $1"; print_usage 1 ;;
        esac
    done
}

# -------------------------------
# Download from URL if given
# -------------------------------
download_url() {
    [[ -z "$_url" ]] && return 0

    gsc_log_info "Downloading from URL: $_url"

    local _tmp_dl
    _tmp_dl=$(mktemp -d)
    gsc_add_tmp_dir "${_tmp_dl}"

    # Derive filename from URL path (strip query string)
    local _fname
    _fname=$(basename "${_url%%\?*}")
    [[ -z "$_fname" || "$_fname" == "/" ]] && _fname="dashboard_download"

    local _dest="${_tmp_dl}/${_fname}"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "${_dest}" "${_url}" || { gsc_log_error "Download failed: $_url"; exit 1; }
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "${_dest}" "${_url}" || { gsc_log_error "Download failed: $_url"; exit 1; }
    else
        gsc_log_error "Neither curl nor wget is available for --url download"; exit 1
    fi

    # If no recognized extension, probe MIME type to add the correct one
    if [[ ! "${_dest}" =~ \.(json|zip|tar\.gz|tar\.xz)$ ]]; then
        if ! command -v file >/dev/null 2>&1; then
            gsc_log_error "Downloaded file '${_fname}' has no recognized extension and 'file' command is unavailable"; exit 1
        fi
        local _mime
        _mime=$(file --mime-type -b "${_dest}")
        case "${_mime}" in
            application/json|text/plain)          mv "${_dest}" "${_dest}.json";   _dest="${_dest}.json" ;;
            application/zip)                      mv "${_dest}" "${_dest}.zip";    _dest="${_dest}.zip" ;;
            application/x-xz|application/x-tar)  mv "${_dest}" "${_dest}.tar.xz"; _dest="${_dest}.tar.xz" ;;
            application/gzip|application/x-gzip) mv "${_dest}" "${_dest}.tar.gz"; _dest="${_dest}.tar.gz" ;;
            *) gsc_log_error "Cannot determine dashboard file type (mime: ${_mime}): ${_dest}"; exit 1 ;;
        esac
    fi

    _dashboards+=("${_dest}")
}

# -------------------------------
# Clone Git repository if given
# -------------------------------
clone_git_repo() {
    [[ -z "$_git_repo" ]] && return 0

    gsc_require git
    gsc_log_info "Cloning Git repo: $_git_repo"

    local _tmp_git
    _tmp_git=$(mktemp -d)
    gsc_add_tmp_dir "${_tmp_git}"

    git clone "$_git_repo" "${_tmp_git}/repo" || { gsc_log_error "Git clone failed."; exit 1; }

    local -a _repo_files=()
    mapfile -t _repo_files < <(find "${_tmp_git}/repo" -type f -name '*.json')
    _dashboards+=("${_repo_files[@]}")
}

# -------------------------------
# Prepare file structure and provisioning
# -------------------------------
prepare_structure() {
    local _preserve_dashboard_dir=0
    local _file
    for _file in "${_dashboards[@]}"; do
        if [[ "${_file}" == "${_dashboard_dir}" ]]; then
            _preserve_dashboard_dir=1
            break
        fi
    done

    if [[ "$_update_dashboards" -eq 0 ]]; then
        if [[ -d "$_dashboard_dir" && ! -w "$_dashboard_dir" ]]; then
            gsc_log_error "Cannot remove '${_dashboard_dir}': permission denied (created by a previous sudo/docker run)."
            gsc_log_error "Fix: sudo rm -rf '${_dashboard_dir}' '${_provisioning_dir}'"
            exit 1
        fi
        if [[ "${_preserve_dashboard_dir}" -eq 0 ]]; then
            rm -rf "$_dashboard_dir"
            mkdir -p "$_dashboard_dir"
        else
            gsc_log_info "Using '${_dashboard_dir}' as both the input dashboard directory and the Grafana staging directory."
            gsc_log_info "Existing dashboard files will be preserved and re-used."
        fi
    fi

    mkdir -p "$_provisioning_dir/dashboards" "$_provisioning_dir/datasources"

    for _file in "${_dashboards[@]}"; do
        if [[ -d "$_file" ]]; then
            ingest_dashboard_dir "$_file"
        else
            case "$_file" in
                *.json)              cp "$_file" "$_dashboard_dir/" ;;
                *.zip|*.tar.gz|*.tar.xz) extract_archive "$_file" ;;
                *) gsc_log_error "Unsupported file type: $_file"; exit 1 ;;
            esac
        fi
    done

    cat > "$_provisioning_dir/dashboards/dashboards.yaml" <<EOF
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
EOF

    cat > "$_provisioning_dir/datasources/datasource.yaml" <<EOF
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: "${_datasource_url}"
    isDefault: true
    editable: true
EOF
}

# -------------------------------
# Poll Grafana health endpoint until ready
# -------------------------------
_wait_for_grafana() {
    local _max_attempts=30 _attempt=0
    gsc_log_info "Waiting for Grafana to be ready..."
    while [[ $_attempt -lt $_max_attempts ]]; do
        if curl -sf "http://localhost:${_grafana_port}/api/health" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
        _attempt=$(( _attempt + 1 ))
    done
    return 1
}

# -------------------------------
# Launch Grafana
# -------------------------------
launch_grafana() {
    local _engine="${_container_engine}"
    # :Z for SELinux private relabeling — supported by podman; skip for docker to avoid issues on non-SELinux hosts
    local _vol_opts=""
    [[ "${_engine}" == "podman" ]] && _vol_opts=":Z"

    "${_engine}" rm -f "${_container_name}" >/dev/null 2>&1 || true

    gsc_log_info "Launching Grafana container '${_container_name}' on port ${_grafana_port} using ${_engine}."
    gsc_log_info "Mounting dashboards from: $(pwd)/${_dashboard_dir}"
    "${_engine}" run -d \
        --name="${_container_name}" \
        -p "${_grafana_port}:3000" \
        -v "$(pwd)/${_dashboard_dir}:/var/lib/grafana/dashboards${_vol_opts}" \
        -v "$(pwd)/${_provisioning_dir}/dashboards:/etc/grafana/provisioning/dashboards${_vol_opts}" \
        -v "$(pwd)/${_provisioning_dir}/datasources:/etc/grafana/provisioning/datasources${_vol_opts}" \
        -e GF_SECURITY_ADMIN_USER=admin \
        -e "GF_SECURITY_ADMIN_PASSWORD=${_admin_password}" \
        grafana/grafana:latest || {
            gsc_log_error "${_engine} run failed for ${_container_name}."
            "${_engine}" ps -a --format '{{.Names}} {{.Status}}' 2>/dev/null | grep -E "^${_container_name} " || true
            exit 1
        }

    if ! _wait_for_grafana; then
        gsc_log_error "${_engine} failed to start Grafana. Cleaning up..."
        "${_engine}" rm -f "${_container_name}" >/dev/null 2>&1 || true
        "${_engine}" image rm grafana/grafana:latest >/dev/null 2>&1 || true
        exit 1
    fi

    gsc_log_ok "Grafana running as '${_container_name}'. Access at http://localhost:${_grafana_port}"
}


# -------------------------------
# Main
# -------------------------------
parse_args "$@"

if [[ "${_cleanup_volumes}" -eq 1 && "${_cleanup_mode}" -eq 0 ]]; then
    gsc_log_error "--volume requires --cleanup"
    print_usage
fi

[[ "${_container_engine}" == "docker" ]] && gsc_require_root

_container_name="$(resolve_container_name)"

if [[ "$_cleanup_mode" -eq 1 ]]; then
    cleanup_grafana
    exit 0
fi

[[ "$_query_mode" -eq 1 ]] && query_prometheus_sources
download_url
clone_git_repo

[[ -z "$_container_engine" ]] && gsc_log_error "Must specify --docker or --podman" && print_usage 1
if [[ $_update_dashboards -eq 0 && ${#_dashboards[@]} -eq 0 ]]; then
    gsc_log_error "At least one dashboard file must be specified with -D, --url, or --git (or use --update to use existing ones)"
    print_usage 1
fi

gsc_require "${_container_engine}" curl
validate_dashboards
prepare_structure
launch_grafana
