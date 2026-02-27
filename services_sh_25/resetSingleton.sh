#!/bin/bash

. ${SERVICE_PACKAGE_DIR}foundry-scripts/funcs.sh

LOCAL_IP=$($SERVICE_TOOLS_DIR/localIp.sh)
RMQ="/usr/lib/rabbitmq/bin/rabbitmqctl --longnames --node=rabbit@$LOCAL_IP"

# Give the node a chance to get set up
log "$0 $LOCAL_IP Waiting 1 minute"
sleep 60

log "$0 $LOCAL_IP querying cluster status"
STATUS=$( $RMQ cluster_status --formatter json )
log "$0 $LOCAL_IP cluster status: $STATUS"
NODES=$( echo $STATUS | python -c "import json; import sys; print(json.loads(sys.stdin.read())['disk_nodes'])" )
log  "$0 $LOCAL_IP nodes: $NODES"
NODE_COUNT=$( (echo $NODES | sed "s/'/\"/g" ) | python -c "import json; import sys; print(len(json.loads(sys.stdin.read())))" )
log  "$0 $LOCAL_IP node count: $NODE_COUNT"

log "$0 $LOCAL_IP querying exchanges"
EXCHANGES=$( $RMQ list_exchanges --formatter json )
log "$0 $LOCAL_IP exchanges: $EXCHANGES"
EXCHANGE_COUNT=$( (echo $EXCHANGES) | python -c "import json; import sys; print(sum((d['name'].startswith('hcpcs.')) for d in json.loads(sys.stdin.read())))" )
log "$0 $LOCAL_IP exchange count: $EXCHANGE_COUNT"

if [ $NODE_COUNT = "1" ]; then
    if [ $EXCHANGE_COUNT = "0" ]; then
        log "$0 $LOCAL_IP stop_app"
        $RMQ stop_app
        log "$0 $LOCAL_IP reset"
        $RMQ reset
        log "$0 $LOCAL_IP start_app"
        $RMQ start_app
    else
        log "$0 $LOCAL_IP skipping reset, non-zero exchange count $EXCHANGE_COUNT"
    fi
else
    log "$0 $LOCAL_IP skipping reset, $NODE_COUNT peers detected"
fi

log "$0 $LOCAL_IP exiting"
