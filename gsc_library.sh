#!/usr/bin/env bash
# gsc_library.sh - compatibility shim; all functions consolidated into gsc_core.sh
_gsc_lib_shim_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${_gsc_lib_shim_dir}/gsc_core.sh"
