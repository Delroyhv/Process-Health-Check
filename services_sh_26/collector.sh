#!/bin/bash

$SERVICE_TOOLS_DIR/serviceInit.sh

. ${SERVICE_PACKAGE_DIR}foundry-scripts/funcs.sh

# Redirect error logs
outlog="$SERVICE_LOG_DIR/collector-service.stdout"
errlog="$SERVICE_LOG_DIR/collector-service.stderr"

redirect_to_log_int "$outlog" "$errlog"

# spans consume very little space - looking at elastic (where they are stored)
# they consume between 50-100 bytes.  Conservatively estimating that they may be up to 512
# bytes, having queue_size at 200,000 will result in ~100MB in use
queue_size=200000

# increase the worker count as each worker that pulls from the queue works on a single
# span at a time.
num_workers=128

sed -i "s/\"param\": .*$/\"param\": ${SAMPLING_RATE}/" conf/sampling-strategy.json
./jaeger-collector --es.server-urls=http://${ELASTICSEARCH_HOST}:${ELASTICSEARCH_PORT} \
    --collector.http-port=${!BOUND_PORT_DEF_COLLECTOR_HTTP_PORT} \
    --collector.port=${!BOUND_PORT_DEF_COLLECTOR_TCHANNEL_PORT} \
    --admin-http-port=${!BOUND_PORT_DEF_COLLECTOR_HEALTH_CHECK_PORT} \
    --sampling.strategies-file=conf/sampling-strategy.json \
    --collector.queue-size=${queue_size} \
    --collector.num-workers=${num_workers} >"$outlog" 2>"$errlog"
