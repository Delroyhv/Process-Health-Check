#!/bin/bash

$SERVICE_TOOLS_DIR/serviceInit.sh

. ${SERVICE_PACKAGE_DIR}foundry-scripts/funcs.sh
. /opt/aspen/scripts/jtools.sh

# Redirect error logs
outlog="$SERVICE_LOG_DIR/gateway-service.stdout"
errlog="$SERVICE_LOG_DIR/gateway-service.stderr"
redirect_to_log_int "$outlog" "$errlog"

MONITORING_PORT=$PORT_DEF_MONITORING_PORT
SUPPORT_PORT=$PORT_DEF_SUPPORT_PORT
DEBUG_PORT=$(get_debug_port)
JMX_PORT=$(get_jmx_port)

RAFT_RPC_PORT=$PORT_DEF_RAFT_RPC_PORT
METADATA_RPC_PORT=$PORT_DEF_METADATA_RPC_PORT

LOCAL_IP=$($SERVICE_TOOLS_DIR/localIp.sh)

DATABASE_STORAGE_DIR=$SERVICE_DATA_DIR
DATABASE_NODE_ID=$SERVICE_INSTANCE_UUID
DATABASE_CONNECTION_HOST=$LOCAL_IP
DATABASE_INITIAL_CONFIG=$DATABASE_STORAGE_DIR/initial_config.json

$SERVICE_TOOLS_DIR/discoveryData.sh $SERVICE_UUID INITIAL_CONFIG > $DATABASE_INITIAL_CONFIG || {
    logError "Failed to get initial config from sentinel"
    exit 1
}

echo "Database storage dir: $DATABASE_STORAGE_DIR" 
echo "Database node id: $DATABASE_NODE_ID"
echo "Database connection host: $DATABASE_CONNECTION_HOST"
echo "Database seed node config: $DATABASE_SEED_NODE_CONFIG"
echo "Database initial config file: $DATABASE_INITIAL_CONFIG"

echo "Initial config: $(cat $DATABASE_INITIAL_CONFIG)"

LOG4J2_CONF_DIR=$(get_logging_conf_directory)
LOGGING_PROPERTIES_FILE=$LOG4J2_CONF_DIR/logging.properties
if test -f $LOGGING_PROPERTIES_FILE; then
  echo "$LOGGING_PROPERTIES_FILE exists, setting LOGGING_PROPERTIES=$LOGGING_PROPERTIES_FILE"
  export LOGGING_PROPERTIES=$LOGGING_PROPERTIES_FILE
fi
CATALINA_OPTS="$(get_java_opts)"
DATABASE_OPTS="-Ddatabase.storage.dir=$DATABASE_STORAGE_DIR -Ddatabase.node.id=$DATABASE_NODE_ID -Ddatabase.connection.host=$DATABASE_CONNECTION_HOST -Dmetadata.intial.config.path=$DATABASE_INITIAL_CONFIG"
GC_OPTS="-XX:+UseG1GC"
RPC_PORT_OPTS="-Dport.rpc.raft=$RAFT_RPC_PORT -Dport.rpc.metadata=$METADATA_RPC_PORT"

# Additional temporary settings for migration on systems with high partition counts
#RAFT_OPTS="-Dcom.hitachi.raft.leaderTimeoutMinNanos=10000000000 -Dcom.hitachi.raft.leaderTimeoutMaxNanos=11000000000 -Dcom.hitachi.raft.followerTimeoutNanos=20000000000 -Dcom.hitachi.raft.heartbeatIntervalMinNanos=5000000000 -Dcom.hitachi.raft.heartbeatIntervalMaxNanos=5500000000 -Dcom.hitachi.raft.followerNonResponsiveTimeoutSeconds=900"

CATALINA_OPTS="$CATALINA_OPTS $RAFT_OPTS $DATABASE_OPTS $RPC_PORT_OPTS $GC_OPTS"

/opt/aspen/scripts/start-tomcat.sh "$LOG4J2_CONF_DIR" "$CATALINA_OPTS" "$MONITORING_PORT" "$SUPPORT_PORT" "$DEBUG_PORT" "$JMX_PORT"


