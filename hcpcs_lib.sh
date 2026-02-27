#!/usr/bin/env bash
# hcpcs_lib.sh – shim to unified gsc_core.sh
# Version: 1.8.26

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${_script_dir}/gsc_core.sh"
