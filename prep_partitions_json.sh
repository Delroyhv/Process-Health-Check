#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ----------------------------------------------------------------------------
# prep_partitions_json.sh
#
# Builds normalized partition JSON from cluster_triage and runs parse scripts:
#   - partMap.json   from *map*.json (slurped into array)
#   - partState.json from *state*.json (slurped into array)
#
# Usage:
#   ./prep_partitions_json.sh [cluster_triage_dir]
# ----------------------------------------------------------------------------

_search_dir="${1:-cluster_triage}"

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${_script_dir}/gsc_core.sh"

gsc_log_info "Preparing partition artifacts under supportLogs/ from: ${_search_dir}"
gsc_prep_partition_artifacts_and_parse "${_search_dir}" "supportLogs"
gsc_log_success "Done. See supportLogs/partitionMap.json, supportLogs/partitionState.json, supportLogs/partitionStateProperties.txt"
