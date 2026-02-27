#!/bin/bash

source "$SERVICE_PACKAGE_DIR/svcbin/service-funcs.sh"

CONTAINER=logstash-service
redirect_to_log $CONTAINER

SERVER_HOST=$($SERVICE_TOOLS_DIR/localIp.sh)
# This URL is referenced in LogstashMonitor
KAFKA_URL=localhost:$KAFKA_PORT

$SERVICE_TOOLS_DIR/serviceInit.sh

if [ ! -f "$SERVICE_DATA_DIR/log.conf.src" ]
then
    log "Copying default logstash configuration template"
    cp "$SERVICE_PACKAGE_DIR/log.conf.src" "$SERVICE_DATA_DIR"
fi

# Default configuration
apply_sed "$SERVICE_DATA_DIR/log.conf.src" "$SERVICE_DATA_DIR/log.conf" \
    "s#KAFKA_SERVER#${KAFKA_URL}#;s#ELASTIC_HOST#localhost:${ELASTIC_PORT}#;s#SYSLOG_PORT#${SYSLOG_PORT}#"

# Custom product configuration
if [ -f "$SERVICE_DATA_DIR/custom_log.conf.src" ]
then
    apply_sed "$SERVICE_DATA_DIR/custom_log.conf.src" "$SERVICE_DATA_DIR/custom_log.conf" \
        "s#KAFKA_SERVER#${KAFKA_URL}#;s#ELASTIC_HOST#localhost:${ELASTIC_PORT}#;s#SYSLOG_PORT#${SYSLOG_PORT}#"
fi

export LS_JAVA_OPTS="$ZK_BUFFER_SIZE"

LOGDIR="$SERVICE_LOG_DIR"
exec /opt/logstash/bin/logstash -f "$SERVICE_DATA_DIR/*.conf" -l "$LOGDIR/logstash.log" --http.port ${!BOUND_PORT_DEF_PRIMARY_PORT} --http.host $SERVER_HOST
