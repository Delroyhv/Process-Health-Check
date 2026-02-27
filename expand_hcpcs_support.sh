#!/usr/bin/env bash
#
# expand_hcpcs_support.sh
#
# Version: 1.8.24
#
_script_version="1.8.24"

set -o errexit
set -o pipefail
set -o nounset

_script_name="$(basename "$0")"
_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

if [ -f "${_script_dir}/gsc_core.sh" ]; then
    # shellcheck source=/dev/null
    . "${_script_dir}/gsc_core.sh"
else
    gsc_log_info()  { printf '[INFO ] %s\n' "$*" >&2; }
    gsc_log_warn()  { printf '[WARN ] %s\n' "$*" >&2; }
    gsc_log_error() { printf '[ERROR] %s\n' "$*" >&2; }
    gsc_die()       { gsc_log_error "$*"; exit 1; }
    gsc_detect_progress_tools() {
        _have_pv=0
        _have_progress=0
        gsc_log_info "gsc_core.sh not found – no pv/progress detection."
    }
fi

###############################################################################
# Globals / defaults
###############################################################################

_root_dir="."

_have_pv=0
_have_progress=0

_space_check_enabled=0
_estimate_only=0

_prom_server="127.0.0.1"
_cs_version=""
_prom_port="9090"
_install_dir="/usr/local/bin/"
_snapshot_file=""
_output_file="healthcheck.conf"
_prom_time_stamp=""

_no_healthcheck=0
_mode="full"          # full | unpack_only | healthcheck_only
_psnap_target=""
_update_only=0        # for --update in healthcheck-only mode
_support_files=()
_prom_server_set=0
_prom_port_set=0
_cs_version_set=0
_install_dir_set=0

###############################################################################
# Usage
###############################################################################
_usage() {
    cat <<EOF
${_script_name} - expand HCP-CS Support Logs and derive psnap healthchecks

Usage:
  ${_script_name} [OPTIONS]

Core options:
  -r, --root-dir DIR        Root directory to search from (default: .)
      --no-healthcheck      Skip healthcheck generation for psnap files
      --healthcheck-only    Only operate on healthcheck config (no unpack)
      -u, --update          In --healthcheck-only mode, update existing
                            healthcheck.conf instead of overwriting
  -P, --psnap FILE          psnap_*.tar.xz file for healthcheck-only mode
                            (optional when using --healthcheck-only with -u)

Healthcheck options:
  -o, --os_version VER      HCP-CS version (override auto-detected _cs_version)
  -s, --prom_server HOST    Prometheus server (default: 127.0.0.1)
  -p, --port PORT           Prometheus port (default: 9090)
  -d, --dir DIR             Install dir for check scripts (default: /usr/local/bin/)
  -f, --file FILE           In normal mode: support log archive to process
                             (may be given multiple times). In
                             --healthcheck-only mode: healthcheck config
                             file (default: healthcheck.conf)

Other:
  -e, --estimate            Enable pre-extract space check (warn/fail thresholds)
      --estimate-only       Only run size/space estimate (no extraction)
      --no-space-check      Disable free-space safety check even if enabled
  -h, --help                Show this help and exit
  -V, --version             Show script version and exit

Examples:
  Normal full run (expand logs + psnap healthchecks):
    ${_script_name} -r /ci/05304447

  Expand only, no healthchecks:
    ${_script_name} -r /ci/05304447 --no-healthcheck

  Healthcheck-only for a single psnap, overriding port:
    ${_script_name} --healthcheck-only -P psnap_2025-Oct-10_13-24-12.tar.xz -p 9091

  Healthcheck-only and update existing healthcheck.conf in-place for a psnap:
    ${_script_name} --healthcheck-only -P psnap_2025-Oct-10_13-24-12.tar.xz -u -p 9091

  Healthcheck-only update of an existing healthcheck.conf (no psnap):
    ${_script_name} --healthcheck-only -u -p 9098 -s prom.example.com -f /path/to/healthcheck.conf
EOF
}
###############################################################################
# CLI parsing
###############################################################################
_parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -r|--root-dir)
                shift
                [ "$#" -gt 0 ] || gsc_die "Missing argument for --root-dir"
                _root_dir="$1"
                ;;
            --no-healthcheck)
                _no_healthcheck=1
                _mode="unpack_only"
                ;;
            --healthcheck-only)
                _mode="healthcheck_only"
                ;;
            -u|--update)
                _update_only=1
                ;;
            -e|--estimate)
                _space_check_enabled=1
                ;;
            --estimate-only|--estimate_only)
                _space_check_enabled=1
                _estimate_only=1
                ;;
            --no-space-check|--no_space_check)
                _space_check_enabled=0
                _estimate_only=0
                ;;
            -P|--psnap)
                shift
                [ "$#" -gt 0 ] || gsc_die "Missing argument for --psnap"
                _psnap_target="$1"
                ;;
            -o|--os_version)
                shift
                [ "$#" -gt 0 ] || gsc_die "Missing argument for --os_version"
                _cs_version="$1"
                _cs_version_set=1
                ;;
            -s|--prom_server)
                shift
                [ "$#" -gt 0 ] || gsc_die "Missing argument for --prom_server"
                _prom_server="$1"
                _prom_server_set=1
                ;;
            -p|--port)
                shift
                [ "$#" -gt 0 ] || gsc_die "Missing argument for --port"
                _prom_port="$1"
                _prom_port_set=1
                ;;
            -d|--dir)
                shift
                [ "$#" -gt 0 ] || gsc_die "Missing argument for --dir"
                _install_dir="$1"
                _install_dir_set=1
                ;;
            -f|--file)
                shift
                [ "$#" -gt 0 ] || gsc_die "Missing argument for --file"
                if [[ "${_mode}" = "healthcheck_only" ]]; then
                    _output_file="$1"
                else
                    _support_files+=("$1")
                fi
                ;;
            -h|--help)
                _usage
                exit 0
                ;;
            -V|--version)
                printf '%s %s\n' "${_script_name}" "${_script_version}"
                exit 0
                ;;
            *)
                gsc_die "Unknown argument: $1"
                ;;
        esac
        shift
    done
}

###############################################################################
# cs_version detection from setup.json
###############################################################################
_update_cs_version_from_setup() {
    # If user already provided -o/--os_version, do not override
    if [ -n "${_cs_version}" ]; then
        return 0
    fi

    local _support_root_dir="$1"
    local _setup_json=""
    local _prod_version=""
    local _derived_version=""

    # Find first setup.json under this SupportLog root
    _setup_json="$(find "${_support_root_dir}" -type f -name 'setup.json' 2>/dev/null | head -n1 || true)"
    if [ -z "${_setup_json}" ]; then
        return 0
    fi

    # Extract productVersion value from JSON, e.g. "2.5.2.3"
    _prod_version="$(
        grep -o '"productVersion"[[:space:]]*:[[:space:]]*"[^"]*"' "${_setup_json}" 2>/dev/null \
        | head -n1 \
        | sed 's/.*"productVersion"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/'
    )"

    if [ -z "${_prod_version}" ]; then
        return 0
    fi

    # Derive 2.x.x style version: keep first 3 components, drop the 4th
    _derived_version="$(
        printf '%s\n' "${_prod_version}" \
        | awk -F. '{
            if (NF>=3)      { printf "%s.%s.%s\n", $1,$2,$3 }
            else if (NF==2) { printf "%s.%s.0\n", $1,$2 }
            else            { print $1 }
        }'
    )"

    if [ -n "${_derived_version}" ]; then
        _cs_version="${_derived_version}"
        gsc_log_info "Detected productVersion ${_prod_version} -> _cs_version=${_cs_version} from ${_setup_json}"
    fi
}

###############################################################################
# Support Logs
###############################################################################
_find_support_logs_files() {
    find "${_root_dir}" -type f -name 'supportLogs_*.tar*.xz' 2>/dev/null | sort
}

_extract_support_log() {
    local _file="$1"
    local _dir _base _target_dir _ts _extract_dir

    _dir="$(dirname -- "${_file}")"
    _base="$(basename -- "${_file}")"
    _ts=""

    if [[ "${_base}" =~ ^supportLogs_([0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2})_ ]]; then
        _ts="${BASH_REMATCH[1]}"
        _target_dir="${_dir}/${_ts}"
    else
        local _core="${_base}"
        # Strip leading 8 digits and a dot, e.g. 05362529.cluster_triage_...
        if [[ "${_core}" =~ ^[0-9]{8}\.(.*)$ ]]; then
            _core="${BASH_REMATCH[1]}"
        fi

        # Handle cluster_triage archives like:
        #   cluster_triage_2025-11-26_20-48-48.tar.20251126.1320.xz
        #   05362529.cluster_triage_2025-11-26_20-48-48.tar.20251126.1320.xz
        # In both cases, use 2025-11-26_20-48-48 as the extract directory name.
        if [[ "${_core}" =~ ^cluster_triage_([0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2})\.tar ]]; then
            _ts="${BASH_REMATCH[1]}"
            _target_dir="${_dir}/${_ts}"
        else
            _target_dir="${_dir}/${_base%%.tar*}"
        fi
    fi

    _extract_dir="${_target_dir}"

    if [ -d "${_extract_dir}" ] && [ -n "$(ls -A "${_extract_dir}" 2>/dev/null || true)" ]; then
        gsc_log_warn "Support Log extract dir already exists and is not empty, skipping: ${_extract_dir}"
        return
    fi

    mkdir -p "${_extract_dir}"
    if [[ "${_space_check_enabled:-0}" -eq 1 ]]; then
        gsc_print_space_estimate "${_file}" "${_extract_dir}" || true
        if ! gsc_check_extract_space "${_file}" "${_extract_dir}"; then
            gsc_die "Insufficient space to extract ${_file} into ${_extract_dir}"
        fi
    fi
    if [[ "${_estimate_only:-0}" -eq 1 ]]; then
        gsc_log_info "Estimate-only mode: not extracting ${_file}"
        return 0
    fi
    gsc_log_info "Extracting Support Log: ${_file} -> ${_extract_dir}"

    if [ "${_have_pv}" -eq 1 ]; then
        pv "${_file}" | xz -d -9 | tar -x -f - -C "${_extract_dir}"
    else
        xz -d -9 -c "${_file}" | tar -x -f - -C "${_extract_dir}"
    fi

    gsc_log_info "Support Log extracted: ${_extract_dir}"

    # After extraction, try to set _cs_version from setup.json if not already set
    _update_cs_version_from_setup "${_extract_dir}"
}

_process_support_logs() {
    local _support_list

    # If the user explicitly provided support log files with -f/--file in
    # normal mode, prefer those over auto-discovery.
    if ((${#_support_files[@]} > 0)); then
        gsc_log_info "Using user-specified support log files:"
        local _file
        for _file in "${_support_files[@]}"; do
            if [ ! -f "${_file}" ]; then
                gsc_log_warn "Support log file not found, skipping: ${_file}"
                continue
            fi
            _extract_support_log "${_file}"
        done
        return
    fi

    _support_list="$(_find_support_logs_files || true)"

    if [ -z "${_support_list}" ]; then
        gsc_log_info "No supportLogs_*.tar*.xz files found under ${_root_dir}"
        return
    fi

    gsc_log_info "Found Support Logs:"
    printf '%s\n' "${_support_list}"

    while IFS= read -r _file; do
        [ -n "${_file}" ] || continue
        _extract_support_log "${_file}"
    done <<< "${_support_list}"
}

###############################################################################
# psnap handling (no unpack)
###############################################################################
_find_prometheus_snapshot_files() {
    find "${_root_dir}" -type f -name '*Prometheus*.tar.xz' 2>/dev/null | sort
}

_extract_date_from_prometheus_name() {
    local _filename="$1"
    basename -- "${_filename}" | awk -F"_" '{ print $(NF-2) "_" $(NF-1) }'
}

_rename_prometheus_file_to_psnap() {
    local _old_path="$1"
    local _dir _base _date_part _new_path

    _dir="$(dirname -- "${_old_path}")"
    _base="$(basename -- "${_old_path}")"
    _date_part="$(_extract_date_from_prometheus_name "${_base}")"

    if [ -z "${_date_part}" ]; then
        gsc_log_warn "Could not extract date part from: ${_old_path} – skipping rename"
        return
    fi

    _new_path="${_dir}/psnap_${_date_part}.tar.xz"

    if [ "${_old_path}" = "${_new_path}" ]; then
        return
    fi

    if [ -e "${_new_path}" ]; then
        gsc_log_warn "Target psnap file already exists, not renaming: ${_new_path}"
        return
    fi

    gsc_log_info "Renaming Prometheus snapshot:"
    gsc_log_info "  old: ${_old_path}"
    gsc_log_info "  new: ${_new_path}"

    mv -- "${_old_path}" "${_new_path}"
}

_rename_all_prometheus_snapshots() {
    local _prom_files
    _prom_files="$(_find_prometheus_snapshot_files || true)"

    if [ -z "${_prom_files}" ]; then
        gsc_log_info "No *Prometheus*.tar.xz files found under ${_root_dir}"
        return
    fi

    while IFS= read -r _prom_file; do
        [ -n "${_prom_file}" ] || continue
        [ -f "${_prom_file}" ] || continue
        _rename_prometheus_file_to_psnap "${_prom_file}"
    done <<< "${_prom_files}"
}

_find_psnap_files() {
    find "${_root_dir}" -type f -name 'psnap*.tar.xz' 2>/dev/null | sort
}

###############################################################################
# Healthcheck generation per psnap in SupportLog directory
###############################################################################
_parse_snapshot_timestamp() {
    _prom_time_stamp=""

    if [ -z "${_snapshot_file}" ]; then
        return 0
    fi

    if [[ "${_snapshot_file}" =~ ^psnap_([0-9]{4})-([A-Za-z]{3})-([0-9]{2})_([0-9]{2})-([0-9]{2})-([0-9]{2})\.tar\.xz$ ]]; then
        local _year="${BASH_REMATCH[1]}"
        local _month_name="${BASH_REMATCH[2]}"
        local _day="${BASH_REMATCH[3]}"
        local _hour="${BASH_REMATCH[4]}"
        local _min="${BASH_REMATCH[5]}"
        local _sec="${BASH_REMATCH[6]}"
        local _month_num

        _month_num="$(date -d "${_month_name} 1" +%m 2>/dev/null || true)"
        if [ -z "${_month_num}" ]; then
            gsc_log_warn "Unable to translate month name '${_month_name}' from ${_snapshot_file}"
            return 1
        fi

        _prom_time_stamp="${_year}-${_month_num}-${_day}T${_hour}:${_min}:${_sec}.000Z"
    else
        gsc_log_warn "Invalid snapshot filename format for timestamp: ${_snapshot_file}"
        return 1
    fi
}

_find_support_dir_for_psnap() {
    # Walk up from the psnap parent directory until we find a directory whose
    # basename matches YYYY-MM-DD_HH-MM-SS (the SupportLog dir).
    local _start_dir="$1"
    local _dir="${_start_dir}"
    local _base

    while [ -n "${_dir}" ] && [ "${_dir}" != "/" ]; do
        _base="$(basename -- "${_dir}")"
        if [[ "${_base}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}$ ]]; then
            printf '%s\n' "${_dir}"
            return 0
        fi
        _dir="$(dirname -- "${_dir}")"
    done

    return 1
}

_count_psnaps_in_support_dir() {
    # $1 = supportLog directory (YYYY-MM-DD_HH-MM-SS)
    find "$1" -maxdepth 1 -type f -name 'psnap*.tar.xz' 2>/dev/null | wc -l
}

_write_full_healthcheck_config() {
    # If we still don't have _cs_version at this point, fall back to a safe default.
    if [ -z "${_cs_version}" ]; then
        _cs_version="2.6"
        gsc_log_warn "No productVersion found in setup.json; defaulting _cs_version=${_cs_version}"
    fi

    cat <<EOF > "${_output_file}"
#Health Check Configuration file Version 2
#HCP CS version 2.5 or 2.6
_cs_version="${_cs_version}"
_prom_server="${_prom_server}"
_prom_port="${_prom_port}"
_prom_time_stamp="${_prom_time_stamp}"
_install_dir="${_install_dir}"
PROM_CMD_PARAM_HOURLY="-c \${_prom_server} -n \${_prom_port} -t \${_prom_time_stamp} -i 360   -e 20 -f \${_install_dir}hcpcs_hourly_alerts.json"
PROM_CMD_PARAM_DAILY="-c \${_prom_server} -n \${_prom_port} -t \${_prom_time_stamp} -i 68400 -e 14 -f \${_install_dir}hcpcs_daily_alerts.json"
VERSION_NUM="\${_cs_version}"
EOF

    gsc_log_info "Healthcheck config created: ${_output_file}"
}

_update_existing_healthcheck_config() {
    # Update only selected fields in an existing healthcheck file
    if [ ! -f "${_output_file}" ]; then
        gsc_log_warn "Requested --update but no existing healthcheck file at ${_output_file}; will create new one."
        _write_full_healthcheck_config
        return
    fi

    gsc_log_info "Updating existing healthcheck config: ${_output_file}"

    # Safely update key lines if they exist; only touch values that were
    # explicitly provided on the CLI (e.g. -p, -s, -o, -d). This allows
    # commands like `--healthcheck-only -u -p 9098` to update only the
    # port while leaving the rest of the file unchanged.
    if [[ "${_prom_port_set}" -eq 1 ]]; then
        sed -i -E "s/^_prom_port=\"[^\"]*\"/_prom_port=\"${_prom_port}\"/" "${_output_file}" 2>/dev/null || true
    fi
    if [[ "${_prom_server_set}" -eq 1 ]]; then
        sed -i -E "s/^_prom_server=\"[^\"]*\"/_prom_server=\"${_prom_server}\"/" "${_output_file}" 2>/dev/null || true
    fi
    if [[ "${_install_dir_set}" -eq 1 ]]; then
        sed -i -E "s/^_install_dir=\"[^\"]*\"/_install_dir=\"${_install_dir}\"/" "${_output_file}" 2>/dev/null || true
    fi

    if [[ "${_cs_version_set}" -eq 1 && -n "${_cs_version}" ]]; then
        sed -i -E "s/^_cs_version=\"[^\"]*\"/_cs_version=\"${_cs_version}\"/" "${_output_file}" 2>/dev/null || true
    fi

    gsc_log_info "Healthcheck config updated: ${_output_file}"
}


_process_single_psnap() {
    local _psnap_xz="$1"
    local _parent_dir _psnap_name _support_dir _target_psnap _psnap_count _safe_stamp

    gsc_log_info "Processing psnap (healthcheck only, no unpack): ${_psnap_xz}"

    [ -f "${_psnap_xz}" ] || {
        gsc_log_warn "File no longer exists, skipping: ${_psnap_xz}"
        return
    }

    _parent_dir="$(dirname -- "${_psnap_xz}")"
    _psnap_name="$(basename -- "${_psnap_xz}")"
    _snapshot_file="${_psnap_name}"
    _prom_time_stamp=""

    if ! _parse_snapshot_timestamp; then
        gsc_log_warn "Skipping healthcheck generation for ${_psnap_xz} due to timestamp parse failure."
        return
    fi

    if ! _support_dir="$(_find_support_dir_for_psnap "${_parent_dir}")"; then
        # Fallback: use parent directory if no SupportLog dir can be found
        _support_dir="${_parent_dir}"
    fi

    mkdir -p "${_support_dir}/cluster_triage"

    _target_psnap="${_support_dir}/${_psnap_name}"
    if [ "${_psnap_xz}" != "${_target_psnap}" ]; then
        mv -f "${_psnap_xz}" "${_target_psnap}"
        gsc_log_info "Moved psnap into SupportLog directory: ${_target_psnap}"
    fi

    if [ "${_no_healthcheck}" -eq 1 ] && [ "${_mode}" != "healthcheck_only" ]; then
        gsc_log_info "--no-healthcheck set, not writing healthcheck config for ${_target_psnap}"
        return
    fi

    # Count how many psnap*.tar.xz are in this SupportLog directory
    _psnap_count="$(_count_psnaps_in_support_dir "${_support_dir}")"

    if [ "${_psnap_count}" -le 1 ]; then
        # Only one psnap in this SupportLog dir → use plain healthcheck.conf
        _output_file="${_support_dir}/healthcheck.conf"
    else
        # Multiple psnaps → first one should have already used healthcheck.conf
        # Subsequent ones get a timestamped suffix
        _safe_stamp="${_prom_time_stamp//:/-}"
        _output_file="${_support_dir}/healthcheck.conf-${_safe_stamp}"
    fi

    if [ "${_update_only}" -eq 1 ]; then
        _update_existing_healthcheck_config
    else
        _write_full_healthcheck_config
    fi
}

_process_all_psnaps() {
    local _psnap_list
    _psnap_list="$(_find_psnap_files || true)"

    if [ -z "${_psnap_list}" ]; then
        gsc_log_warn "No psnap*.tar.xz files found"
        return
    fi

    while IFS= read -r _psnap_xz; do
        [ -n "${_psnap_xz}" ] || continue
        _process_single_psnap "${_psnap_xz}"
    done <<< "${_psnap_list}"
}

###############################################################################
# Main
###############################################################################
_main_expand() {
    _parse_args "$@"

    if [ "${_mode}" = "healthcheck_only" ]; then
        if [ -n "${_psnap_target}" ]; then
            [ -f "${_psnap_target}" ] || gsc_die "psnap file not found: ${_psnap_target}"
            gsc_log_info "Healthcheck-only for psnap (no unpack): ${_psnap_target}"
            _process_single_psnap "${_psnap_target}"
            gsc_log_info "Done (healthcheck-only for psnap)."
            exit 0
        fi

        # No psnap target provided: allow pure healthcheck.conf update when -u is given
        if [ "${_update_only}" -ne 1 ]; then
            gsc_die "--healthcheck-only without -P/--psnap requires -u/--update to modify an existing healthcheck.conf"
        fi

        # By default operate on healthcheck.conf in the current directory unless overridden by -f/--file
        : "${_output_file:=healthcheck.conf}"
        gsc_log_info "Healthcheck-only update of existing healthcheck config: ${_output_file}"
        _update_existing_healthcheck_config
        gsc_log_info "Done (healthcheck-only update)."
        exit 0
    fi

    [ -d "${_root_dir}" ] || gsc_die "Root directory does not exist: ${_root_dir}"

    gsc_detect_progress_tools
    gsc_log_info "Root directory: ${_root_dir}"

    _process_support_logs
    _rename_all_prometheus_snapshots
    _process_all_psnaps

    if [ "${_no_healthcheck}" -eq 1 ]; then
        gsc_log_info "Finished expanding Support Logs, psnap healthchecks skipped"
    else
        gsc_log_info "Finished expanding Support Logs and generating psnap healthcheck configs"
    fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    _main_expand "$@"
fi