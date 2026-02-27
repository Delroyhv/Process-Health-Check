#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Script: setup-grafana.sh
# Description: Sets up a Grafana container with specified dashboards using Docker or Podman.
#              Supports dashboard files, URLs, git repositories, and compressed archives.
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
_datasource_url="http://prometheus:9090"
_script_name=$(basename "$0")
_dashboard_dir="dashboards"
_provisioning_dir="provisioning"
_timestamp=$(date +%Y%m%d_%H%M%S)
_error_log="${_timestamp}.error.log"

# -------------------------------
# Helper: Print usage
# -------------------------------
print_usage() {
    cat <<EOF
Usage: $_script_name [-p|--podman] [-d|--docker] -D|--dashboard [file2 ...] [--url http://...] [--git https://...] [-i ip:port]

Options:
  -p, --podman           Use Podman as the container engine
  -d, --docker           Use Docker as the container engine
  -D, --dashboard FILE   Add one or more dashboard JSON or archive files
  --url URL              Download dashboard archive or JSON from URL
  --git URL              Clone a Git repository containing dashboard JSON files
  -i, --input IP:PORT    Specify the Prometheus datasource IP and port (e.g., 172.22.20.26:9090)

Example:
  sudo $_script_name --docker -D dashboard1.json dashboards.zip
  sudo $_script_name --docker --url https://example.com/dashboards.zip
  sudo $_script_name --podman --git https://github.com/example/grafana-dashboards -i 172.22.20.26:9090
EOF
    exit 1
}

# -------------------------------
# Check if running as root
# -------------------------------
check_root() {
    [[ "${EUID:-$(id -u)}" -ne 0 ]] && echo "This script must be run as root." && exit 1
}

# -------------------------------
# Validate dashboard files
# -------------------------------
validate_dashboards() {
    for _file in "${_dashboards[@]}"; do
        [[ ! -f "$_file" ]] && echo "❌ Dashboard file not found: $_file" && exit 1
    done
}

# -------------------------------
# Extract supported archives
# -------------------------------
extract_archive() {
    local _archive="$1"
    mkdir -p "$_dashboard_dir"
    case "$_archive" in
        *.zip) unzip -o "$_archive" -d "$_dashboard_dir" ;;
        *.tar.gz) tar -xzf "$_archive" -C "$_dashboard_dir" ;;
        *.tar.xz) tar -xJf "$_archive" -C "$_dashboard_dir" ;;
        *) echo "❌ Unsupported archive format: $_archive" && exit 1 ;;
    esac
}

# -------------------------------
# Parse command-line arguments
# -------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--podman) _container_engine="podman"; shift ;;
            -d|--docker) _container_engine="docker"; shift ;;
            -D|--dashboard)
                shift
                while [[ $# -gt 0 && ! "$1" =~ ^- ]]; do
                    _dashboards+=("$1")
                    shift
                done
                ;;
            --url)
                shift
                _url="$1"; shift ;;
            --git)
                shift
                _git_repo="$1"; shift ;;
            -i|--input)
                shift
                _datasource_url="http://$1"; shift ;;
            -*|--*) echo "❌ Unknown option: $1"; print_usage ;;
        esac
    done
}

# -------------------------------
# Download from URL if given
# -------------------------------
download_url() {
    if [[ -n "$_url" ]]; then
        echo "📥 Downloading from URL: $_url"
        mkdir -p temp_download
        curl -L -o temp_download/downloaded_file "$_url" || wget -O temp_download/downloaded_file "$_url"
        _dashboards+=("temp_download/downloaded_file")
    fi
}

# -------------------------------
# Clone Git repository if given
# -------------------------------
clone_git_repo() {
    if [[ -n "$_git_repo" ]]; then
        echo "Cloning Git repo: $_git_repo"
        git clone "$_git_repo" temp_git || { echo "Git clone failed."; exit 1; }
        local -a _repo_files=()
        mapfile -t _repo_files < <(find temp_git -type f -name '*.json')
        _dashboards+=("${_repo_files[@]}")
    fi
}

# -------------------------------
# Prepare file structure and provisioning
# -------------------------------
prepare_structure() {
    mkdir -p "$_dashboard_dir" "$_provisioning_dir/dashboards" "$_provisioning_dir/datasources"

    for _file in "${_dashboards[@]}"; do
        case "$_file" in
            *.json) cp "$_file" "$_dashboard_dir/" ;;
            *.zip|*.tar.gz|*.tar.xz) extract_archive "$_file" ;;
            *) echo "❌ Unsupported file type: $_file" && exit 1 ;;
        esac
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
    url: $_datasource_url
    isDefault: true
EOF

    cat > docker-compose.yaml <<EOF
version: '3'
services:
  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    ports:
      - "3000:3000"
    volumes:
      - ./dashboards:/var/lib/grafana/dashboards
      - ./provisioning/dashboards:/etc/grafana/provisioning/dashboards
      - ./provisioning/datasources:/etc/grafana/provisioning/datasources
    environment:
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SECURITY_ADMIN_PASSWORD=admin
EOF
}

# -------------------------------
# Launch Grafana
# -------------------------------
launch_grafana() {
    if [[ "$_container_engine" == "docker" ]]; then
        docker compose up -d 2>>"$_error_log"
        sleep 5
        if ! docker ps | grep -q grafana; then
            echo "❌ Docker failed to start Grafana. Cleaning up..." | tee -a "$_error_log"
            docker compose down 2>>"$_error_log"
            docker image rm grafana/grafana:latest 2>>"$_error_log"
            exit 1
        fi
    else
        podman run -d \
            --name=grafana \
            -p 3000:3000 \
            -v "$(pwd)/dashboards:/var/lib/grafana/dashboards:Z" \
            -v "$(pwd)/provisioning/dashboards:/etc/grafana/provisioning/dashboards:Z" \
            -v "$(pwd)/provisioning/datasources:/etc/grafana/provisioning/datasources:Z" \
            -e GF_SECURITY_ADMIN_USER=admin \
            -e GF_SECURITY_ADMIN_PASSWORD=admin \
            grafana/grafana:latest 2>>"$_error_log"
        sleep 5
        if ! podman ps | grep -q grafana; then
            echo "❌ Podman failed to start Grafana. Cleaning up..." | tee -a "$_error_log"
            podman rm -f grafana 2>>"$_error_log"
            podman image rm grafana/grafana:latest 2>>"$_error_log"
            exit 1
        fi
    fi
    echo "✅ Grafana setup complete. Access it at http://localhost:3000"
}

# -------------------------------
# Main
# -------------------------------
check_root
parse_args "$@"
download_url
clone_git_repo
[[ -z "$_container_engine" ]] && echo "❌ Must specify --docker or --podman" && print_usage
[[ ${#_dashboards[@]} -eq 0 ]] && echo "❌ At least one dashboard file must be specified with -D, --url, or --git" && print_usage
validate_dashboards
prepare_structure
launch_grafana
