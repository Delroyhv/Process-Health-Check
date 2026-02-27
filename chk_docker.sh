#!/usr/bin/env bash
#
# ========================================================================
# Copyright (c) by Hitachi Vantara, 2024. All rights reserved.
# ========================================================================
#
# Parse collected Docker diagnostic files from cluster nodes. Produces a
# per-node summary of Docker version, container state, inotify limits,
# and ulimit locked-memory. Flags nodes exceeding health thresholds.
#
# Air-gapped deployments: gpgcheck=0, file:// yum repos, and missing
# repo config files are expected and are NOT flagged.
#
# Thresholds:
#   Docker version major < 25    : WARNING — EOL / unsupported since 2024
#   Exited container (any)       : WARNING — service not running
#   Stale exited (month/year old): WARNING — orphaned, remove or restart
#   inotify max_user_instances
#     < 8192                     : WARNING — may exhaust under container load
#   max locked memory != unlimited: WARNING — mlock() constrained for
#                                    containers (Kafka, ES performance impact)
#
# References:
#   https://docs.docker.com/engine/release-notes/
#     Docker Engine release notes and EOL schedule
#   https://docs.docker.com/engine/containers/resource_constraints/
#     Container resource constraints: ulimits, memory locking
#   https://docs.docker.com/reference/cli/docker/container/ls/
#     docker ps output format and STATUS field meanings
#

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${_script_dir}/gsc_core.sh"

_default_output_file="health_report_docker.log"
_default_docker_log="docker.log"
_log_dir="."
_output_file="${_default_output_file}"
_docker_log="${_default_docker_log}"
_err=0

# Thresholds (override via environment)
_DOCKER_MIN_MAJOR=${DOCKER_MIN_MAJOR:-25}
_INOTIFY_MIN=${DOCKER_INOTIFY_MIN:-8192}

usage() {
    local _this_filename
    _this_filename=$(basename "$0")
    echo "\
Parse Docker diagnostics across all cluster nodes.

${_this_filename} [-d <dir>] [-o <output>]

  -d <dir>     directory with support bundle (default: .)
  -o <output>  output log file (default: ${_default_output_file})
"
}

getOptions() {
    while getopts "d:o:h" _opt; do
        case "${_opt}" in
            d) _log_dir="${OPTARG}" ;;
            o) _output_file="${OPTARG}" ;;
            *) usage; exit 0 ;;
        esac
    done
}

############################

getOptions "$@"

gsc_log_info "== CHECKING DOCKER HEALTH =="

gsc_rotate_log "${_output_file}"
: > "${_docker_log}"

mapfile -t _ver_files < <(find "${_log_dir}" -name '*_dockerinfo_docker-v.out' \
    ! -name '*.err' 2>/dev/null | sort)

if [[ "${#_ver_files[@]}" -eq 0 ]]; then
    gsc_loga "WARNING: No docker diagnostic files found in ${_log_dir}"
    exit 0
fi

gsc_log_info "Found ${#_ver_files[@]} node(s) with docker diagnostics"

# Print summary table header
_hdr=$(printf '%-38s %-12s %-18s %-10s %-12s' \
    "Node" "Docker" "Containers" "inotify" "Locked-Mem")
_sep=$(printf '%-38s %-12s %-18s %-10s %-12s' \
    "----" "------" "----------" "-------" "----------")
gsc_loga ""
gsc_loga "${_hdr}"
gsc_loga "${_sep}"

for _file in "${_ver_files[@]}"; do

    _node=$(basename "${_file}" \
        | sed 's/^node_info_//; s/_[0-9]\{4\}-[A-Z][a-z][a-z]-.*//')

    # Derive sibling file paths from anchor prefix
    _prefix="${_file%_*_dockerinfo_docker-v.out}"
    _ps_file="${_prefix}_3_dockerinfo_docker-ps-a.out"
    _inotify_file="${_prefix}_2_perfinfo_docker-proc-sys-fs-inotify-max_user_instances.out"
    _ulimit_file="${_prefix}_2_perfinfo_docker-ulimit-Ha.out"

    # Append raw content to docker.log
    {
        printf '=== %s ===\n' "${_node}"
        echo "-- docker version --"
        cat "${_file}"
        if [[ -f "${_ps_file}" ]]; then
            echo "-- docker ps -a --"
            cat "${_ps_file}"
        fi
        echo ""
    } >> "${_docker_log}"

    # Docker version
    _docker_ver=$(awk '{print $3}' "${_file}" | tr -d ',')
    _docker_major=$(echo "${_docker_ver}" | cut -d. -f1)

    # Container counts from docker-ps-a
    _total=0; _running=0; _exited=0
    if [[ -f "${_ps_file}" ]]; then
        _total=$(grep -cE '^[a-f0-9]{12}' "${_ps_file}" 2>/dev/null || true)
        _running=$(grep -c ' Up ' "${_ps_file}" 2>/dev/null || true)
        _exited=$(grep -c 'Exited' "${_ps_file}" 2>/dev/null || true)
        _total=${_total:-0}; _running=${_running:-0}; _exited=${_exited:-0}
    fi
    _ctr_str="${_running}/${_total}"
    [[ "${_exited}" -gt 0 ]] && _ctr_str="${_ctr_str} (${_exited} exit)"

    # inotify max_user_instances — line 2 is the first value (after first container header)
    _inotify_val="?"
    if [[ -f "${_inotify_file}" ]]; then
        _inotify_val=$(awk 'NR==2{print; exit}' "${_inotify_file}")
    fi

    # max locked memory hard limit — first occurrence in ulimit-Ha file
    _locked_mem="?"
    if [[ -f "${_ulimit_file}" ]]; then
        _locked_mem=$(awk '/max locked memory/{print $NF; exit}' "${_ulimit_file}")
    fi
    if [[ "${_locked_mem}" =~ ^[0-9]+$ ]]; then
        _locked_mem_disp="${_locked_mem} kB"
    else
        _locked_mem_disp="${_locked_mem}"
    fi

    gsc_loga "$(printf '%-38s %-12s %-18s %-10s %-12s' \
        "${_node}" "${_docker_ver}" "${_ctr_str}" \
        "${_inotify_val}" "${_locked_mem_disp}")"

    _node_issues=0

    # Docker version — warn if major version is EOL
    if [[ "${_docker_major}" =~ ^[0-9]+$ ]] && \
       [[ "${_docker_major}" -lt "${_DOCKER_MIN_MAJOR}" ]]; then
        ((_node_issues++)); ((_err++))
        gsc_loga "WARNING: ${_node}: Docker ${_docker_ver} is EOL (major ${_docker_major} < ${_DOCKER_MIN_MAJOR}) — plan upgrade to a supported release"
    fi

    # Exited containers
    if [[ -f "${_ps_file}" ]]; then
        while IFS= read -r _cline; do
            _cname=$(awk '{print $NF}' <<< "${_cline}")
            _cstatus=$(echo "${_cline}" | grep -oE 'Exited \([0-9]+\) [0-9]+ [a-z]+ ago')
            if echo "${_cline}" | grep -qE '[0-9]+ (months?|years?) ago'; then
                ((_node_issues++)); ((_err++))
                gsc_loga "WARNING: ${_node}: stale exited container '${_cname}' — ${_cstatus} — remove or restart"
            else
                ((_node_issues++)); ((_err++))
                gsc_loga "WARNING: ${_node}: exited container '${_cname}' — ${_cstatus}"
            fi
        done < <(grep 'Exited' "${_ps_file}" 2>/dev/null)
    fi

    # inotify max_user_instances
    if [[ "${_inotify_val}" =~ ^[0-9]+$ ]] && \
       [[ "${_inotify_val}" -lt "${_INOTIFY_MIN}" ]]; then
        ((_node_issues++)); ((_err++))
        gsc_loga "WARNING: ${_node}: inotify max_user_instances=${_inotify_val} below recommended ${_INOTIFY_MIN} — add fs.inotify.max_user_instances=${_INOTIFY_MIN} to /etc/sysctl.conf and run sysctl -p"
    fi

    # max locked memory — numeric means limited (not unlimited)
    if [[ "${_locked_mem}" =~ ^[0-9]+$ ]]; then
        ((_node_issues++)); ((_err++))
        gsc_loga "WARNING: ${_node}: max locked memory hard limit=${_locked_mem} kB — containers cannot mlock() heap; set 'hard memlock unlimited' in /etc/security/limits.d/docker.conf or via systemd drop-in"
    fi

done

gsc_loga ""
gsc_loga "INFO: Full docker output saved to ${_docker_log}"

if [[ "${_err}" -gt 0 ]]; then
    gsc_loga "Detected ${_err} issue(s)"
else
    gsc_loga "INFO: All nodes within normal Docker parameters"
fi

gsc_log_info "Saved results ${_output_file}"
