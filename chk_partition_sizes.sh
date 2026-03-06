#!/usr/bin/env bash
#
# ========================================================================
# Copyright (c) by Hitachi Vantara, 2024. All rights reserved.
# ========================================================================
#
# Analyze partitionSize values from clusterPartitionState_Metadata-Coordination_*.json
# files collected in a support bundle.
#
# For each partition, extracts: partitionId, partitionSize (bytes), keySpaceId,
# nodeCount. Sorts by partitionSize descending, writes a flat log file, and
# emits a WARNING when the largest partition size is >= 1.5× the configured
# split threshold (indicating MDCO may not be splitting partitions correctly).
#
# Output files:
#   health_report_partition_sizes.log   — WARNING/INFO lines (in summary)
#   partition_size_analysis.log         — flat tab-separated data file
#
# Threshold source: "Partition split thresholds (largest: ...)" line from
#   health_report_partitionInfo.log (written by chk_partInfo.sh).
#
# Implementation: Go binary (chk_partition_sizes) with jq fallback.
#   Go binary: faster, handles unit parsing (1Gi/G/Mi/M → bytes),
#              deduplicates across multiple JSON files, avoids jq's
#              verbose to_entries[] pattern on large objects.
#

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${_script_dir}/gsc_core.sh"

_default_output_file="health_report_partition_sizes.log"
_default_flat_file="partition_size_analysis.log"
_log_dir="."
_output_file="${_default_output_file}"
_flat_file="${_default_flat_file}"
_err=0

usage() {
    local _this_filename
    _this_filename=$(basename "$0")
    echo "\
Analyze partitionSize from clusterPartitionState_Metadata-Coordination_*.json.

${_this_filename} [-d <dir>] [-o <output>]

  -d <dir>     support bundle directory to search (default: .)
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

gsc_log_info "== CHECKING PARTITION SIZES =="

gsc_rotate_log "${_output_file}"

# ── Locate split threshold ────────────────────────────────────────────────────
# Read the "largest:" threshold from health_report_partitionInfo.log (written
# by chk_partInfo.sh, which runs before this script in runchk.sh).
_split_threshold=""
_info_log="${_log_dir}/health_report_partitionInfo.log"
[[ ! -f "${_info_log}" ]] && _info_log="health_report_partitionInfo.log"
if [[ -f "${_info_log}" ]]; then
    _split_threshold=$(grep "Partition split thresholds (largest:" "${_info_log}" 2>/dev/null \
        | sed -n 's/.*largest: \([^)]*\)).*/\1/p' || true)
fi

if [[ -n "${_split_threshold}" ]]; then
    gsc_log_info "Split threshold: ${_split_threshold}"
else
    gsc_log_info "Split threshold not found — size check skipped"
fi

# ── Platform detection ────────────────────────────────────────────────────────
_os=$(uname -s | tr '[:upper:]' '[:lower:]')
_arch=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
_bin="${_script_dir}/chk_partition_sizes/build/chk_partition_sizes-${_os}-${_arch}"

# ── Go binary dispatch ────────────────────────────────────────────────────────
if [[ -x "${_bin}" ]]; then
    _threshold_arg=""
    [[ -n "${_split_threshold}" ]] && _threshold_arg="--threshold ${_split_threshold}"

    # shellcheck disable=SC2086
    while IFS= read -r _line; do
        [[ -z "${_line}" ]] && continue
        gsc_loga "${_line}"
        # Count issues for summary
        if echo "${_line}" | grep -q "^\[WARNING\]"; then
            ((_err++))
        fi
    done < <("${_bin}" \
        --dir "${_log_dir}" \
        ${_threshold_arg} \
        --output "${_flat_file}" \
        2>/dev/null)

# ── jq fallback ──────────────────────────────────────────────────────────────
elif command -v jq >/dev/null 2>&1; then
    gsc_log_warn "chk_partition_sizes binary not found — using jq fallback (slower)"

    mapfile -t _json_files < <(find "${_log_dir}" \
        -name 'clusterPartitionState_Metadata-Coordination_*.json' \
        2>/dev/null | sort)

    if [[ "${#_json_files[@]}" -eq 0 ]]; then
        gsc_loga "WARN   : No clusterPartitionState_Metadata-Coordination_*.json files found"
    else
        # Extract and sort; deduplicate by partitionId via sort -u on field 1
        {
            echo "# partition_size_analysis — jq fallback (${#_json_files[@]} file(s))"
            echo -e "# partitionId\tpartitionSize\tkeySpaceId\tnodeCount"
            jq -rs '
                [ .[] | to_entries[] | .value
                  | { id: .partitionId, sz: .partitionSize,
                      ks: .keySpaceId, nc: (.nodes | length) } ]
                | unique_by(.id)
                | sort_by(-.sz)[]
                | [.id, .sz, .ks, .nc]
                | @tsv
            ' "${_json_files[@]}" 2>/dev/null
        } > "${_flat_file}"

        _max_size=$(awk 'NR>2 && !/^#/{print $2; exit}' "${_flat_file}")
        _count=$(awk '!/^#/{c++} END{print c+0}' "${_flat_file}")
        echo "# largest_partition_size: ${_max_size}" >> "${_flat_file}"

        gsc_loga "INFO   : chk_partition_sizes (jq): ${_count} partitions; largest: ${_max_size} bytes → ${_flat_file}"

        # Threshold check (integer arithmetic only — strip non-numeric suffix)
        if [[ -n "${_split_threshold}" && -n "${_max_size}" ]]; then
            _thresh_num="${_split_threshold//[^0-9]/}"
            # Multiply by unit: Gi/G=1073741824, Mi/M=1048576, Ki/K=1024
            _thresh_bytes="${_thresh_num}"
            case "${_split_threshold}" in
                *[Gg][Ii]|*[Gg]) _thresh_bytes=$(( _thresh_num * 1073741824 )) ;;
                *[Mm][Ii]|*[Mm]) _thresh_bytes=$(( _thresh_num * 1048576 ))    ;;
                *[Kk][Ii]|*[Kk]) _thresh_bytes=$(( _thresh_num * 1024 ))       ;;
            esac
            # 2*max >= 3*thresh ↔ max >= 1.5*thresh
            if (( 2 * _max_size >= 3 * _thresh_bytes )); then
                ((_err++))
                gsc_loga "WARNING: ${_split_threshold} Partitions are larger than expected (largest: ${_max_size} bytes). MDCO may need investigation."
            fi
        fi
    fi
else
    gsc_log_warn "chk_partition_sizes binary and jq not found — skipping partition size analysis"
    gsc_loga "INFO   : Install chk_partition_sizes binary (cd chk_partition_sizes && make all) or jq"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
if [[ "${_err}" -gt 0 ]]; then
    gsc_loga "Detected ${_err} partition size issue(s)"
else
    gsc_loga "INFO   : Partition size check complete"
fi

gsc_log_info "Saved results to ${_output_file}"
