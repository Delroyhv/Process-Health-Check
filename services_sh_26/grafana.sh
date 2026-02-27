#!/bin/bash

$SERVICE_TOOLS_DIR/serviceInit.sh

. ${SERVICE_PACKAGE_DIR}foundry-scripts/funcs.sh

# Redirect error logs
outlog="$SERVICE_LOG_DIR/grafana-service.stdout"
errlog="$SERVICE_LOG_DIR/grafana-service.stderr"

redirect_to_log_int "$outlog" "$errlog"

./usr/bin/grafana/bin/grafana-server --config /usr/share/grafana/conf/config.ini -homepath /usr/share/grafana cfg:default.server.http_port=${!BOUND_PORT_DEF_GRAFANA_PORT}