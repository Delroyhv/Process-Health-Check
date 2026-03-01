#!/bin/bash
set -euo pipefail

# Default config values
#_cs_version="2.6"
_prom_server="127.0.0.1"
_cs_version=$(chk_cluster.sh 2>/dev/null | grep version | awk '{print $4}' | uniq) || true
_prom_port="9151"
_install_dir="/usr/local/bin/"
_snapshot_file=""
_prom_time_stamp=""
_output_file="healthcheck.conf"
_update_mode=false

#######################################
# Help message
#######################################
show_help() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  -o, --os_version     Set HCP-CS version (default: 2.6)
  -s, --prom_server    Set Prometheus server (IP or FQDN)
  -p, --port           Set Prometheus port (default: 9151)
  -d, --dir            Set install directory (default: /usr/local/bin/)
  -P, --psnap          Set Prometheus snapshot filename
  -u, --update         Update healthcheck.conf in-place if it exists
  -h, --help           Show this help message
EOF
}

#######################################
# Parse CLI args
#######################################
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -o|--os_version)   _cs_version="$2"; shift 2 ;;
            -s|--prom_server)  _prom_server="$2"; shift 2 ;;
            -p|--port)         _prom_port="$2"; shift 2 ;;
            -d|--dir)          _install_dir="$2"; shift 2 ;;
            -P|--psnap)        _snapshot_file="$2"; shift 2 ;;
            -u|--update)       _update_mode=true; shift ;;
            -h|--help)         show_help; exit 0 ;;
            *) echo "❌ Unknown option: $1"; show_help; exit 1 ;;
        esac
    done
}

#######################################
# Convert snapshot filename to UTC timestamp
# Format: YYYY-MM-DDTHH:MM:SS.000Z
#######################################
parse_snapshot_timestamp() {
    if [[ -n "$_snapshot_file" ]]; then
        if [[ "$_snapshot_file" =~ psnap_([0-9]{4})-([A-Za-z]{3})-([0-9]{2})_([0-9]{2})-([0-9]{2})-([0-9]{2}) ]]; then
            local year="${BASH_REMATCH[1]}"
            local month_name="${BASH_REMATCH[2]}"
            local day="${BASH_REMATCH[3]}"
            local hour="${BASH_REMATCH[4]}"
            local min="${BASH_REMATCH[5]}"
            local sec="${BASH_REMATCH[6]}"
            local month_num
            month_num=$(date -d "$month_name 1" +%m 2>/dev/null)
            _prom_time_stamp="${year}-${month_num}-${day}T${hour}:${min}:${sec}.000Z"
        else
            echo "❌ Invalid snapshot filename format: $_snapshot_file" >&2
            exit 1
        fi
    fi
}

#######################################
# In-place update existing config
#######################################
update_config_in_place() {
    if [[ ! -f "$_output_file" ]]; then
        echo "❌ Config file not found: $_output_file"
        exit 1
    fi

    echo "⚙️ Updating $_output_file..."

    [[ -n "$_cs_version" ]] && sed -i "s/^_cs_version=.*/_cs_version=\"$_cs_version\"/" "$_output_file"
    [[ -n "$_prom_server" ]] && sed -i "s/^_prom_server=.*/_prom_server=\"$_prom_server\"/" "$_output_file"
    [[ -n "$_prom_port" ]] && sed -i "s/^_prom_port=.*/_prom_port=\"$_prom_port\"/" "$_output_file"
    [[ -n "$_install_dir" ]] && sed -i "s|^_install_dir=.*|_install_dir=\"$_install_dir\"|" "$_output_file"
    [[ -n "${_prom_time_stamp:-}" ]] && sed -i "s/^_prom_time_stamp=.*/_prom_time_stamp=\"$_prom_time_stamp\"/" "$_output_file"

    echo "✅ Updated successfully."
    exit 0
}

#######################################
# Write full config from scratch
#######################################
write_full_config() {
    cat <<EOF > "$_output_file"
#Health Check Configuration file Verssion 2
# set varibles
#HCP CS version 2.5 or 2.6
_cs_version="${_cs_version}"
# Prometheus Server FQDN or IP address
_prom_server="${_prom_server}"
#Prometheus PORT number
_prom_port="${_prom_port}"
#Prometheus Time stamp  YYYY-MM-DDTHH:MM:SS.000Z in Zulu/UTC this obtained from prometheus snapshot file
_prom_time_stamp="${_prom_time_stamp}"
#Install DIR where check scriptts are installed
_install_dir="${_install_dir}"
#Daily and Hourly Commands Do not Modify Below this line.
PROM_CMD_PARAM_HOURLY="-c \${_prom_server} -n \${_prom_port} -t  \${_prom_time_stamp} -i 360 -e 20 -f \${_install_dir}hcpcs_hourly_alerts.json"
PROM_CMD_PARAM_DAILY="-c \${_prom_server} -n \${_prom_port} -t \${_prom_time_stamp} -i 68400 -e 14 -f \${_install_dir}hcpcs_daily_alerts.json"
VERSION_NUM="\${_cs_version}"
EOF

    echo "✅ healthcheck.conf created."
}

#######################################
# Main Entry
#######################################
main() {
    parse_args "$@"
    parse_snapshot_timestamp

    if [[ "$_update_mode" == true ]]; then
        update_config_in_place
    else
        write_full_config
    fi
}

main "$@"
