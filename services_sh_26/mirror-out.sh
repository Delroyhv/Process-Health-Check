#!/bin/bash

$SERVICE_TOOLS_DIR/serviceInit.sh

. ${SERVICE_PACKAGE_DIR}foundry-scripts/funcs.sh
. /opt/aspen/scripts/jtools.sh

MONITORING_PORT=$PORT_DEF_MONITORING_PORT
SUPPORT_PORT=$PORT_DEF_SUPPORT_PORT
DEBUG_PORT=$(get_debug_port)
JMX_PORT=$(get_jmx_port)

LOG4J2_CONF_DIR=$(get_logging_conf_directory)

VERTX_OPTS="$(get_min_heap_opt) $(get_java_opts)"

# Redirect error logs
outlog="$SERVICE_LOG_DIR/policy-mirror-out.stdout"
errlog="$SERVICE_LOG_DIR/policy-mirror-out.stderr"

redirect_to_log_int "$outlog" "$errlog"

/opt/aspen/scripts/start-vertx.sh "$LOG4J2_CONF_DIR" "$VERTX_OPTS" "$MONITORING_PORT" "$SUPPORT_PORT" "$DEBUG_PORT" "$JMX_PORT"
