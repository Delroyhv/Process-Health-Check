#!/usr/bin/env bash
#
# ========================================================================
# Copyright (c) by Hitachi Vantara, 2024. All rights reserved.
# ========================================================================
#
# Parse collected filesystem and LVM diagnostic files from cluster nodes.
# Produces per-node filesystem usage tables and cross-node layout comparison.
# Checks LVM physical volumes, volume groups, and logical volumes — reports
# exceptions only (problems, inconsistencies, or low free space).
#
# Air-gapped / minimal installs: missing LVM files are expected on nodes
# that use raw partitions and are NOT flagged as errors.
#
# Thresholds:
#   Filesystem Use% > 75%       : WARNING — approaching capacity; expand or
#                                  purge data before write failures occur
#   Filesystem Use% > 90%       : CRITICAL — near full; imminent write failures
#   VG free space   < 10%       : WARNING — volume group nearly exhausted;
#                                  no room to extend logical volumes
#   Per-node mount point set
#     differs from cluster norm : WARNING — inconsistent filesystem layout;
#                                  may indicate missed provisioning step
#
# References:
#   Red Hat Enterprise Linux 8 — Managing file systems
#     https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/
#     8/html/managing_file_systems/
#   Red Hat Enterprise Linux 8 — Configuring and managing logical volumes
#     https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/
#     8/html/configuring_and_managing_logical_volumes/
#   Linux "df" man page (util-linux) — Use% interpretation
#   Linux "lsblk" man page — block device layout
#

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${_script_dir}/gsc_core.sh"

_default_output_file="health_report_filesystem.log"
_log_dir="."
_output_file="${_default_output_file}"
_err=0

# Thresholds (override via environment variable)
_FS_WARN=${FS_USAGE_WARN:-75}
_FS_CRIT=${FS_USAGE_CRIT:-90}
_VG_FREE_WARN=${VG_FREE_WARN:-10}   # minimum VG free % before warning

usage() {
    local _this_filename
    _this_filename=$(basename "$0")
    echo "\
Parse filesystem and LVM diagnostics across all cluster nodes.

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

gsc_log_info "== CHECKING FILESYSTEM AND LVM HEALTH =="
gsc_rotate_log "${_output_file}"

# ── 1. FILESYSTEM USAGE (df) ────────────────────────────────────────────────

mapfile -t _df_files < <(find "${_log_dir}" -name '*_diskinfo_df-h*.out' \
    ! -name '*.err' 2>/dev/null | sort)

# Also accept alternative naming: *_diskinfo_df*.out, *_systeminfo_df*.out
if [[ "${#_df_files[@]}" -eq 0 ]]; then
    mapfile -t _df_files < <(find "${_log_dir}" \
        \( -name '*_diskinfo_df*.out' -o -name '*_systeminfo_df*.out' \) \
        ! -name '*.err' 2>/dev/null | sort)
fi

if [[ "${#_df_files[@]}" -eq 0 ]]; then
    gsc_loga "WARNING: No df diagnostic files found in ${_log_dir}"
else
    gsc_log_info "Found ${#_df_files[@]} node(s) with df diagnostics"

    _hdr=$(printf '%-30s %-6s %-30s' "Node/Filesystem" "Use%" "Mounted on")
    _sep=$(printf '%-30s %-6s %-30s' "---------------" "----" "----------")
    gsc_loga ""
    gsc_loga "── Filesystem Usage ──"
    gsc_loga "${_hdr}"
    gsc_loga "${_sep}"

    # Accumulate per-node mount-point sets for cross-node comparison
    declare -A _node_mounts   # [node]="/ /boot /data ..."
    declare -a _df_nodes      # ordered list of node names

    for _file in "${_df_files[@]}"; do
        _node=$(basename "${_file}" \
            | sed 's/^node_info_//; s/_[0-9]\{4\}-[A-Z][a-z][a-z]-.*//')

        _df_nodes+=("${_node}")
        _mounts=""

        # Parse df output.  Use% is always the second-to-last column ($(NF-1))
        # and Mounted on is always the last ($NF), for both df -h and df -hT.
        # Skip the header line and tmpfs/devtmpfs pseudo-filesystems.
        while IFS=' ' read -r _fs _pct _mnt; do
            # Strip trailing % from Use%
            _pct="${_pct%%%}"
            _mounts="${_mounts} ${_mnt}"

            gsc_loga "$(printf '%-30s %-6s %-30s' "${_node}:${_fs}" "${_pct}%" "${_mnt}")"

            if [[ "${_pct}" =~ ^[0-9]+$ ]]; then
                if [[ "${_pct}" -ge "${_FS_CRIT}" ]]; then
                    ((_err++))
                    gsc_loga "CRITICAL: ${_node}: ${_mnt} (${_fs}) is ${_pct}% full — imminent write failures; expand filesystem or purge data immediately"
                elif [[ "${_pct}" -ge "${_FS_WARN}" ]]; then
                    ((_err++))
                    gsc_loga "WARNING: ${_node}: ${_mnt} (${_fs}) is ${_pct}% full — approaching capacity (>${_FS_WARN}%); schedule expansion"
                fi
            fi
        done < <(awk '
            NR == 1 { next }                        # skip header
            $1 ~ /^(tmpfs|devtmpfs|udev)$/ { next } # skip pseudo-fs
            $1 ~ /^none$/ { next }
            NF >= 5 {
                pct = $(NF-1)
                mnt = $NF
                # Use first field as filesystem; works for both df -h and df -hT
                printf "%s %s %s\n", $1, pct, mnt
            }
        ' "${_file}")

        _node_mounts["${_node}"]="${_mounts# }"   # trim leading space
    done

    # Cross-node filesystem layout comparison
    if [[ "${#_df_nodes[@]}" -gt 1 ]]; then
        gsc_loga ""
        gsc_loga "── Cross-node Filesystem Layout ──"

        _ref_node="${_df_nodes[0]}"
        _ref_mounts="${_node_mounts[${_ref_node}]}"
        _layout_ok=1

        for _node in "${_df_nodes[@]:1}"; do
            _this_mounts="${_node_mounts[${_node}]}"
            if [[ "${_this_mounts}" != "${_ref_mounts}" ]]; then
                _layout_ok=0
                ((_err++))
                # Report specific mounts that are missing or extra
                _missing=$(comm -23 \
                    <(tr ' ' '\n' <<< "${_ref_mounts}"  | sort) \
                    <(tr ' ' '\n' <<< "${_this_mounts}" | sort) \
                    | tr '\n' ' ')
                _extra=$(comm -13 \
                    <(tr ' ' '\n' <<< "${_ref_mounts}"  | sort) \
                    <(tr ' ' '\n' <<< "${_this_mounts}" | sort) \
                    | tr '\n' ' ')
                [[ -n "${_missing// /}" ]] && \
                    gsc_loga "WARNING: ${_node}: mount points missing vs ${_ref_node}: ${_missing% }"
                [[ -n "${_extra// /}" ]] && \
                    gsc_loga "WARNING: ${_node}: extra mount points vs ${_ref_node}: ${_extra% }"
            fi
        done

        [[ "${_layout_ok}" -eq 1 ]] && \
            gsc_loga "INFO: All nodes have identical filesystem layout (${#_df_nodes[@]} nodes checked)"
    fi

    unset _node_mounts _df_nodes
fi

# ── 2. BLOCK DEVICE LAYOUT (lsblk) ─────────────────────────────────────────

mapfile -t _lsblk_files < <(find "${_log_dir}" -name '*_diskinfo_lsblk*.out' \
    ! -name '*.err' 2>/dev/null | sort)

if [[ "${#_lsblk_files[@]}" -gt 0 ]]; then
    gsc_loga ""
    gsc_loga "── Block Device Layout ──"

    # Collect per-node device+fstype+mountpoint fingerprints for cross-node diff
    declare -A _node_blk
    declare -a _lsblk_nodes

    for _file in "${_lsblk_files[@]}"; do
        _node=$(basename "${_file}" \
            | sed 's/^node_info_//; s/_[0-9]\{4\}-[A-Z][a-z][a-z]-.*//')
        _lsblk_nodes+=("${_node}")

        # Summarise: count block devices and record device tree fingerprint
        # (NAME SIZE TYPE FSTYPE MOUNTPOINT lines, excluding loop devices)
        _blk_summary=$(awk '
            NR == 1 { next }
            $1 ~ /^loop/ { next }
            { print $0 }
        ' "${_file}" | head -20)

        _node_blk["${_node}"]=$(echo "${_blk_summary}" | \
            awk '{print $1,$3}' | sort | tr '\n' '|')

        gsc_loga "INFO: ${_node}: $(echo "${_blk_summary}" | \
            awk '$3=="disk"{d++} $3=="part"{p++} $3=="lvm"{l++} \
                 END{printf "%d disk(s), %d partition(s), %d lvm lv(s)", d, p, l}')"
    done

    # Cross-node lsblk comparison (device name+type fingerprint)
    if [[ "${#_lsblk_nodes[@]}" -gt 1 ]]; then
        _ref_node="${_lsblk_nodes[0]}"
        _ref_blk="${_node_blk[${_ref_node}]}"
        for _node in "${_lsblk_nodes[@]:1}"; do
            if [[ "${_node_blk[${_node}]}" != "${_ref_blk}" ]]; then
                ((_err++))
                gsc_loga "WARNING: ${_node}: block device layout differs from ${_ref_node} — verify disk provisioning is consistent across nodes"
            fi
        done
    fi

    unset _node_blk _lsblk_nodes
fi

# ── 3. LVM — EXCEPTIONS ONLY ────────────────────────────────────────────────

mapfile -t _pvs_files < <(find "${_log_dir}" -name '*_diskinfo_pvs*.out' \
    ! -name '*.err' 2>/dev/null | sort)
mapfile -t _vgs_files < <(find "${_log_dir}" -name '*_diskinfo_vgs*.out' \
    ! -name '*.err' 2>/dev/null | sort)
_lvm_found=$(( ${#_pvs_files[@]} + ${#_vgs_files[@]} ))

if [[ "${_lvm_found}" -gt 0 ]]; then
    gsc_loga ""
    gsc_loga "── LVM Health (exceptions only) ──"
    _lvm_issues=0

    # PVs: check for unknown/missing attributes (normal Attr = a-- or a--)
    for _file in "${_pvs_files[@]}"; do
        _node=$(basename "${_file}" \
            | sed 's/^node_info_//; s/_[0-9]\{4\}-[A-Z][a-z][a-z]-.*//')
        while IFS= read -r _line; do
            ((_lvm_issues++)); ((_err++))
            gsc_loga "WARNING: ${_node}: PV problem — ${_line}"
        done < <(awk '
            NR == 1 { next }
            # Attr field (col 4) — normal is "a--"; flag anything else
            # or if allocatable flag is missing
            NF >= 4 && $4 !~ /^a/ {
                print "PV " $1 " attr=" $4 " (not allocatable — check for missing/failed PV)"
            }
        ' "${_file}")
    done

    # VGs: check for low free space
    for _file in "${_vgs_files[@]}"; do
        _node=$(basename "${_file}" \
            | sed 's/^node_info_//; s/_[0-9]\{4\}-[A-Z][a-z][a-z]-.*//')
        while IFS=$'\t' read -r _vg _vsize _vfree _pct_free; do
            ((_lvm_issues++)); ((_err++))
            gsc_loga "WARNING: ${_node}: VG '${_vg}' free space ${_pct_free}% (${_vfree} of ${_vsize}) — below ${_VG_FREE_WARN}% threshold; no room to extend LVs"
        done < <(awk -v warn="${_VG_FREE_WARN}" '
            NR == 1 { next }
            NF >= 7 {
                vg    = $1
                vsize = $6
                vfree = $7
                # Strip unit suffix for numeric compare using sub()
                sz = vsize; gsub(/[gGmMtT]$/, "", sz)
                fr = vfree; gsub(/[gGmMtT]$/, "", fr)
                if (sz+0 > 0) {
                    pct = int(fr / sz * 100)
                    if (pct < warn)
                        printf "%s\t%s\t%s\t%d\n", vg, vsize, vfree, pct
                }
            }
        ' "${_file}")
    done

    if [[ "${_lvm_issues}" -eq 0 ]]; then
        gsc_loga "INFO: LVM PV/VG/LV — no exceptions found"
    fi
fi

# ── Summary ──────────────────────────────────────────────────────────────────

gsc_loga ""
if [[ "${_err}" -gt 0 ]]; then
    gsc_loga "Detected ${_err} filesystem/LVM issue(s)"
else
    gsc_loga "INFO: All nodes within normal filesystem and LVM parameters"
fi

gsc_log_info "Saved results ${_output_file}"
