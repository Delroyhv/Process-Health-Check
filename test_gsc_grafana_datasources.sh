#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

_tmp_dir=$(mktemp -d)
trap 'rm -rf -- "${_tmp_dir}" >/dev/null 2>&1 || true' EXIT

_output="$("${PWD}/gsc_grafana.sh" --url dummy --list-datasources 2>&1)"
echo "${_output}" | grep -q 'Prometheus \[ds_'
echo "${_output}" | grep -q 'http://127.0.0.1:9090'

_uid=$(printf '%s\n' "${_output}" | sed -n 's/.*Prometheus \[\(ds_[^]]*\)\].*/\1/p' | head -n1)
[[ -n "${_uid}" ]]

_removed="$("${PWD}/gsc_grafana.sh" --url dummy --remove-datasource "${_uid}" --list-datasources 2>&1)"
echo "${_removed}" | grep -q 'Resolved datasource entries'
if echo "${_removed}" | grep -q "Prometheus \[${_uid}\]"; then
  echo "Datasource UID was not removed: ${_uid}" >&2
  exit 1
fi

echo "[OK] gsc_grafana datasource regression passed"


