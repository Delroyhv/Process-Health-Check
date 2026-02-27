#!/bin/bash

$SERVICE_TOOLS_DIR/serviceInit.sh

. ${SERVICE_PACKAGE_DIR}foundry-scripts/funcs.sh

# Redirect error logs
outlog="$SERVICE_LOG_DIR/agent-service.stdout"
errlog="$SERVICE_LOG_DIR/agent-service.stderr"

redirect_to_log_int "$outlog" "$errlog"

./jaeger-agent --http-server.host-port=":${PORT_DEF_AGENT_HTTP_PORT}" --reporter.tchannel.host-port=${COLLECTOR_HOST}:${COLLECTOR_PORT}