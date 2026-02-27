#!/bin/bash

source "$SERVICE_PACKAGE_DIR/svcbin/service-funcs.sh"

CONTAINER=chronos-service
redirect_to_log $CONTAINER

MESOS_ZOOKEEPER_URL=$($SERVICE_TOOLS_DIR/zookeeperUrl.sh mesos)
#Chronos uses a zeparate zk_path argument for the path under chronos. Default is fine.
CHRONOS_ZOOKEEPER_URL=$($SERVICE_TOOLS_DIR/zookeeperUrl.sh "")

$SERVICE_TOOLS_DIR/serviceInit.sh

JAVA_HEAP=${MAX_HEAP_SIZE:-"512m"}

exec java -Xmx$JAVA_HEAP $ZK_BUFFER_SIZE -cp /opt/chronos-2.5.0/chronos-2.5.0.jar org.apache.mesos.chronos.scheduler.Main --master zk://${MESOS_ZOOKEEPER_URL} --zk_hosts ${CHRONOS_ZOOKEEPER_URL} --http_port ${!BOUND_PORT_DEF_PRIMARY_PORT} --http_address "$($SERVICE_TOOLS_DIR/localIp.sh)" --reconciliation_interval 300
