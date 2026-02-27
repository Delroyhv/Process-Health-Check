#!/bin/bash

$SERVICE_TOOLS_DIR/serviceInit.sh

. ${SERVICE_PACKAGE_DIR}foundry-scripts/funcs.sh

MONITORING_PORT=$PORT_DEF_MONITORING_PORT
SUPPORT_PORT=$PORT_DEF_SUPPORT_PORT
DEBUG_PORT=$(get_debug_port)
JMX_PORT=$(get_jmx_port)

CACHE_TCP_DISC_PORT=${!BOUND_PORT_DEF_CACHE_TCP_DISC_PORT:-47500}
CACHE_TCP_CONN_PORT=$PORT_DEF_CACHE_TCP_CONN_PORT

LOG4J2_CONF_DIR=$(get_logging_conf_directory)
VERTX_OPTS="$(get_java_opts) -Dport.cache.tcp.disc=$CACHE_TCP_DISC_PORT -Dport.cache.tcp.conn=$CACHE_TCP_CONN_PORT"

# Redirect error logs
outlog="$SERVICE_LOG_DIR/metadata-cache-service.stdout"
errlog="$SERVICE_LOG_DIR/metadata-cache-service.stderr"

redirect_to_log_int "$outlog" "$errlog"

/opt/aspen/scripts/start-vertx.sh "$LOG4J2_CONF_DIR" "$VERTX_OPTS" "$MONITORING_PORT" "$SUPPORT_PORT" "$DEBUG_PORT" "$JMX_PORT"
