#!/bin/bash

source "$SERVICE_PACKAGE_DIR/svcbin/service-funcs.sh"

CONTAINER=elastic-service
redirect_to_log $CONTAINER

$SERVICE_TOOLS_DIR/serviceInit.sh

ADVERTISED_HOST=$($SERVICE_TOOLS_DIR/localIp.sh)

SEED_NODES=$($SERVICE_TOOLS_DIR/discoveryData.sh $SERVICE_UUID HOST_LIST) || {
    logError "Failed to get seed nodes from elastic"
    exit 1
}

QUORUM=$($SERVICE_TOOLS_DIR/discoveryData.sh $SERVICE_UUID QUORUM) || {
    logError "Failed to get QUORUM from elastic"
    exit 1
}

ES_SEED_IPS=""

cp $SERVICE_PACKAGE_DIR/log4j2.properties /opt/elasticsearch/config/log4j2.properties
cp $SERVICE_PACKAGE_DIR/jvm.options /opt/elasticsearch/config/jvm.options

if [ "z$SEED_NODES" != "z" ] && [ "z$SEED_NODES" != "znull" ]
then
    # must be the first node
    ES_SEED_IPS="-Ediscovery.zen.ping.unicast.hosts=$SEED_NODES"
fi

ES_QUORUM=""
if [ "z$QUORUM" != "z" ] && [ "z$QUORUM" != "znull" ]
then
    # Even though we're setting quorum here, we still need the scale action that sets qurom on the cluster
    ES_QUORUM="-Ediscovery.zen.minimum_master_nodes=$QUORUM"
fi

# We're binding to all local IPs, but only publishing to the external. We also pass the --quiet
# option here to stop the duplicate logging to stdout
exec /opt/elasticsearch/bin/elasticsearch --quiet -Ehttp.bind_host=$ADVERTISED_HOST -Ehttp.publish_host=$ADVERTISED_HOST -Enetwork.bind_host=$ADVERTISED_HOST -Enetwork.publish_host=$ADVERTISED_HOST \
-Etransport.tcp.port=$PORT_DEF_SECONDARY_PORT -Etransport.publish_port=$PORT_DEF_SECONDARY_PORT -Ehttp.port=$PORT_DEF_PRIMARY_PORT -Ehttp.publish_port=$PORT_DEF_PRIMARY_PORT \
-Epath.data="$SERVICE_DATA_DIR" -Epath.logs="$SERVICE_LOG_DIR" -Ediscovery.zen.ping_timeout=30s $ES_SEED_IPS $ES_QUORUM
