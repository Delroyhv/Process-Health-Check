#!/bin/bash

$SERVICE_TOOLS_DIR/serviceInit.sh

. ${SERVICE_PACKAGE_DIR}foundry-scripts/funcs.sh

# Redirect error logs
outlog="$SERVICE_LOG_DIR/metrics-service.stdout"
errlog="$SERVICE_LOG_DIR/metrics-service.stderr"

redirect_to_log_int "$outlog" "$errlog"

CONFIG_PATH="${SERVICE_DATA_DIR}etc/prometheus"
mkdir -p "${CONFIG_PATH}"
CONFIG_FILE="${CONFIG_PATH}/prometheus.yml"

PROMETHEUS_YML=$($SERVICE_TOOLS_DIR/internalConfig.sh prometheus-config)
echo "${PROMETHEUS_YML}" > "${CONFIG_FILE}"
cat "${CONFIG_FILE}"

TSDB_PATH="${SERVICE_DATA_DIR}${PROMETHEUS_DB_PATH}"
echo
echo TSDB_PATH: "${TSDB_PATH}"

#sed -i "s/scrape_interval: .*$/scrape_interval: ${PROMETHEUS_SCRAPE_INTERVAL}/" /etc/prometheus/prometheus.yml
prometheus --config.file="${CONFIG_FILE}" --web.listen-address=:${!BOUND_PORT_DEF_PROMETHEUS_PORT} --web.enable-lifecycle --storage.tsdb.retention="${PROMETHEUS_DB_RETENTION}" --storage.tsdb.path="${TSDB_PATH}"
