#!/bin/bash

$SERVICE_TOOLS_DIR/serviceInit.sh

. ${SERVICE_PACKAGE_DIR}foundry-scripts/funcs.sh

# Redirect error logs
outlog="$SERVICE_LOG_DIR/query-service.stdout"
errlog="$SERVICE_LOG_DIR/query-service.stderr"

redirect_to_log_int "$outlog" "$errlog"

./jaeger-query --query.static-files jaeger-ui-build --es.server-urls=http://${ELASTICSEARCH_HOST}:${ELASTICSEARCH_PORT} - --query.port=${!BOUND_PORT_DEF_QUERY_HTTP_PORT} --admin-http-port=${!BOUND_PORT_DEF_QUERY_HEALTH_CHECK_PORT}
