#!/bin/bash

source "$SERVICE_PACKAGE_DIR/svcbin/service-funcs.sh"

CONTAINER=cassandra-service
redirect_to_log $CONTAINER

$SERVICE_TOOLS_DIR/serviceInit.sh

SERVICE_TOOLS_LIB=$(readlink -f "$SERVICE_TOOLS_DIR/../lib")
CASSANDRA_DATA_HOME="$SERVICE_DATA_DIR"
CASSANDRA_DATA_HOME=$(escape_spaces "$CASSANDRA_DATA_HOME")
export CASSANDRA_DATA_HOME
export CASSANDRA_CONFIG="$SERVICE_PACKAGE_DIR/conf"

CASSANDRA_SRC="$CASSANDRA_CONFIG/cassandra.yaml.src"
CASSANDRA_YAML="$SERVICE_DATA_DIR/cassandra.yaml"
BROADCAST_ADDRESS=$($SERVICE_TOOLS_DIR/localIp.sh)

SEED_NODES=$($SERVICE_TOOLS_DIR/discoveryData.sh $SERVICE_UUID HOST_LIST) || {
    logError "Failed to get seed nodes from sentinel"
    exit 1
}
if [ "z$SEED_NODES" = "z" ] || [ "z$SEED_NODES" = "znull" ]
then
    # must be the first node
    SEED_NODES="${BROADCAST_ADDRESS}"
fi

COMPACTION_THROUGHPUT=$($SERVICE_TOOLS_DIR/discoveryData.sh $SERVICE_UUID compactionThroughput) || {
    logError "Failed to get compaction throughput from sentinel"
    exit 1
}

STREAM_THROUGHPUT=$($SERVICE_TOOLS_DIR/discoveryData.sh $SERVICE_UUID streamThroughput) || {
    logError "Failed to get stream throughput from sentinel"
    exit 1
}

apply_sed "$CASSANDRA_SRC" "$CASSANDRA_YAML" "\
s#BROADCAST_ADDRESS#$BROADCAST_ADDRESS#;\
s#SEED_NODES#$SEED_NODES#;\
s#NATIVE_TRANSPORT_PORT#$PORT_DEF_PRIMARY_PORT#;\
s#STORAGE_PORT#$PORT_DEF_SECONDARY_PORT#;\
s#COMPACTION_THROUGHPUT#$COMPACTION_THROUGHPUT#;\
s#STREAM_THROUGHPUT#$STREAM_THROUGHPUT#;"

# enable JMX security. See https://wiki.apache.org/cassandra/JmxSecurity
JMX_PASS_FILE="/opt/cassandra/conf/jmxremote.password"
JMX_ACCESS_FILE="/opt/cassandra/conf/jmxremote.access"
CASSANDRA_ENV="/opt/cassandra/conf/cassandra-env.sh"
CASSANDRA_ENV_TMP="${CASSANDRA_ENV}.tmp"

# Currently we don't need to ever disable ssl for jmx because update for cassandra already updates
# the service plugin before the service, but we'll leave the ability to do so here in case
# something comes up in the future.
JMX_SSL_ENABLED=true
CASSANDRA_ENV_SED_OPTIONS="\
s|LOCAL_JMX=yes|LOCAL_JMX=no|;\
s|JMX_PORT=\"7199\"|JMX_PORT=\"$PORT_DEF_PRIMARY_SERVICE_PORT\"|;\
s|JVM_OPTS=\"\$JVM_OPTS -ea\"|#JVM_OPTS=\"\$JVM_OPTS -ea\"|;\
s|JVM_OPTS=\"\$JVM_OPTS -Xloggc|#JVM_OPTS=\"\$JVM_OPTS -Xloggc|;"

if [[ $JMX_SSL_ENABLED == true ]]; then
    CASSANDRA_ENV_SED_OPTIONS=$CASSANDRA_ENV_SED_OPTIONS"\
s|JVM_OPTS=\"\$JVM_OPTS -Dcom.sun.management.jmxremote.ssl=false\"|JVM_OPTS=\"\$JVM_OPTS -Dcom.sun.management.jmxremote.ssl=true\"|;\
s|#  JVM_OPTS=\"\$JVM_OPTS -Dcom.sun.management.jmxremote.ssl.need.client.auth=true\"|  JVM_OPTS=\"\$JVM_OPTS -Dcom.sun.management.jmxremote.ssl.need.client.auth=true\"|;\
s|JVM_OPTS=\"\$JVM_OPTS -Dcom.sun.management.jmxremote.password.file=/etc/cassandra/jmxremote.password\"|JVM_OPTS=\"\$JVM_OPTS -Dcom.sun.management.jmxremote.password.file=$JMX_PASS_FILE -Dcom.sun.management.jmxremote.access.file=$JMX_ACCESS_FILE\"|;\
s|#  JVM_OPTS=\"\$JVM_OPTS -Dcom.sun.management.jmxremote.registry.ssl=true\"|  JVM_OPTS=\"\$JVM_OPTS -Dcom.sun.management.jmxremote.registry.ssl=true\"|;\
s|#  JVM_OPTS=\"\$JVM_OPTS -Djavax.net.ssl.keyStore=/path/to/keystore\"|  JVM_OPTS=\"\$JVM_OPTS -Djavax.net.ssl.keyStore=$SERVICE_TOOLS_LIB/foundryJmxKeyStore.jks\"|;\
s|#  JVM_OPTS=\"\$JVM_OPTS -Djavax.net.ssl.keyStorePassword=<keystore-password>\"|  JVM_OPTS=\"\$JVM_OPTS -Djavax.net.ssl.keyStorePassword=ensemble\"|;\
s|#  JVM_OPTS=\"\$JVM_OPTS -Djavax.net.ssl.trustStore=/path/to/truststore\"|  JVM_OPTS=\"\$JVM_OPTS -Djavax.net.ssl.trustStore=$SERVICE_TOOLS_LIB/foundryJmxTrustStore.jks\"|;\
s|#  JVM_OPTS=\"\$JVM_OPTS -Djavax.net.ssl.trustStorePassword=<truststore-password>\"|  JVM_OPTS=\"\$JVM_OPTS -Djavax.net.ssl.trustStorePassword=ensemble\"|;"
fi

cp $CASSANDRA_ENV $CASSANDRA_ENV_TMP
apply_sed "$CASSANDRA_ENV_TMP" "$CASSANDRA_ENV" "$CASSANDRA_ENV_SED_OPTIONS"

grep cassandra $JMX_PASS_FILE || echo "cassandra ensemble" >> $JMX_PASS_FILE
chmod 400 $JMX_PASS_FILE

grep cassandra $JMX_ACCESS_FILE || echo "cassandra readwrite" >> $JMX_ACCESS_FILE
chmod 400 $JMX_ACCESS_FILE

cp "$CASSANDRA_CONFIG/cassandra-rackdc.properties" "/opt/cassandra/conf/cassandra-rackdc.properties"
cp "$CASSANDRA_CONFIG/logback.xml" "/opt/cassandra/conf/logback.xml"

# Create the cassandra properties file so nodetool can communicate to cassandra nodes that are
# now protected by authenticated JMX

# FNDD-4199 - Create nodetool properties file or SSL comunication
# Make sure the required directory exists where the properties file needs to be
mkdir -p /root/.cassandra

# now create the properity file in the required directory with the required name
echo "-Dcom.sun.management.jmxremote.ssl=true
-Dcom.sun.management.jmxremote.ssl.need.client.auth=true
-Dcom.sun.management.jmxremote.registry.ssl=true
-Djavax.net.ssl.keyStore=/opt/service/tools/lib/foundryJmxKeyStore.jks
-Djavax.net.ssl.keyStorePassword=ensemble
-Djavax.net.ssl.trustStore=/opt/service/tools/lib/foundryJmxTrustStore.jks
-Djavax.net.ssl.trustStorePassword=ensemble" > /root/.cassandra/nodetool-ssl.properties

exec /opt/cassandra/bin/cassandra -f -Dcassandra.config=file://$CASSANDRA_YAML -Dlogback.configurationFile=$CASSANDRA_CONFIG/logback.xml -Dcassandra.logdir=$SERVICE_LOG_DIR -Dcassandra.storagedir=$SERVICE_DATA_DIR/data/ -Djava.rmi.server.hostname=${BROADCAST_ADDRESS}
