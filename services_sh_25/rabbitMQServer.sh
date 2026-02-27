#!/bin/bash

$SERVICE_TOOLS_DIR/serviceInit.sh

. ${SERVICE_PACKAGE_DIR}foundry-scripts/funcs.sh

# Ensure trap on ERR is inherited by commands executed in a subshell so our
# fail() function will behave properly if invoked from a subshell (which
# is typical usage).
set -E
trap '[ "$?" -ne 99 ] || exit 99' ERR

# Redirect error logs
outlog="$SERVICE_LOG_DIR/rabbit-service.stdout"
errlog="$SERVICE_LOG_DIR/rabbit-service.stderr"

redirect_to_log_int "$outlog" "$errlog"

# Location to write erlang cookie. The HOME location is only used by the CLI tools,
# and as such a copy would be necessary in the HOME folder of each user requiring
# tool access. /var/lib/rabbitmq/.erlang.cookie for the server to use. See
# https://www.rabbitmq.com/cli.html#erlang-cookie.
RABBITMQ_ERLANG_COOKIE=/var/lib/rabbitmq/.erlang.cookie
RABBITMQ_ERLANG_USER_COOKIE=~/.erlang.cookie

# Function to exit the script using the special value 99. This is used by
# get_internal_config in conjunction with the trap handler to exit from any
# level of subshell invocation.
function fail {
    logError "Fatal error detected. Exiting startup script."
    exit 99
}

# Tries to fetch the value for key $1 from internalConfig with retries.
# This method assumes a value of empty is invalid and will retry to get
# the config value when returned an empty string. If all retry attempts to
# get the value are exhausted, the script will exit and the container
# will bounce. Only call this for values which must be fetched from
# internalConfig and for which an empty string is an invalid value.
function get_internal_config() {
    # Any error logs must redirect to stderr since callers will
    # expect stdout to contain the value for the supplied key.
    local n=1
    local max=60
    local delay=1
    while true; do
        local val
        val=$($SERVICE_TOOLS_DIR/internalConfig.sh $1)
        if [[ -z "$val" ]]; then
            if [[ $n -lt $max ]]; then
                logError "get_internal_config '$1' failed. Attempt $n/$max"
                ((n++))
                sleep $delay;
            else
                logError "get_internal_config '$1' failed. Attempt $n/$max"
                logError "script exiting with error. The container should restart."
                fail
            fi
        else
            echo $val
            break
        fi
    done
}

function update_erlang_cookie() {
    echo "$(get_internal_config erlangCookie)" > $RABBITMQ_ERLANG_COOKIE
    chmod 400 $RABBITMQ_ERLANG_COOKIE
    cp $RABBITMQ_ERLANG_COOKIE $RABBITMQ_ERLANG_USER_COOKIE
}

# 3 arguments: sourcefile, destfile, pattern to apply.
# multiple replacements can be combined into one string with ; between them
# e.g. apply_sed source dest "s#INSTALLDIR#$INSTALLDIR#;s#SOLRINSTANCE#$solrinstance#"
apply_sed () {
    #source and dest should be absolute paths
    local sourcefile=$1
    local destfile=$2
    local pattern=$3
    # log "pattern=$pattern sourcefile=$sourcefile destfile=$destfile"
    sed -e "$pattern" "$sourcefile" > "$destfile"
}

function update_config_file() {
    local defaultuser=$1
    local defaultpass=$2
    local consumertimeout=$3
    apply_sed /etc/rabbitmq/rabbitmq.conf /etc/rabbitmq/rabbitmq.conf_updated "s#DEFAULT_MANAGEMENT_PORT#${RABBITMQ_MANAGEMENT_PORT_INTERNAL}#;s#DEFAULT_PORT#${RABBITMQ_NODE_PORT}#;s#DEFAULT_USER#${defaultuser}#;s#DEFAULT_PASS#${defaultpass}#;s#DEFAULT_MONITORING_PORT#${RABBITMQ_MONITORING_PORT}#;s#CONSUMER_TIMEOUT#${consumertimeout}#;"
    cp /etc/rabbitmq/rabbitmq.conf_updated /etc/rabbitmq/rabbitmq.conf
    rm /etc/rabbitmq/rabbitmq.conf_updated
}

# Rabbit is not docker-aware. It will assume it's memory limits are based on
# the host, not the container. Override based on container allocation.
# https://www.rabbitmq.com/memory.html
container_mem_limit=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)
log "Container memory limit is $container_mem_limit"
if [ -z "$container_mem_limit" ]
then
    log "RabbitMQ failed to read memory.limit_in_bytes. No memory override."
else
    # Rabbit will start throttling publish at 40% of this limit. This accounts
    # for erlang vm gc overhead which can double use (80% of limit)
    #
    # See ASP-11684. Best practice we would reserve some memory from rabbit for the OS.
    log "RabbitMQ Server overriding memory to $container_mem_limit"
    echo "total_memory_available_override_value = $container_mem_limit" >> /etc/rabbitmq/rabbitmq.conf
fi

# Prefer throttling to paging. Although the documentation says paging can be disabled
# by setting this value above 1.0, doing so results in a crash during initialization
# "[error] vm_memory_high_watermark_paging_ratio invalid, Float is not between 0 and 1"
echo "vm_memory_high_watermark_paging_ratio = 0.9" >> /etc/rabbitmq/rabbitmq.conf

# Allow setting logging level here vs. in the template config so that it can more
# easily be altered in the field
echo "log.file.level = info" >> /etc/rabbitmq/rabbitmq.conf

# Set to true to disable built-in statistics collection from RabbitMQ UI and
# rely solely on RabbitMQ-related stats are already being collected via Prometheus
# To disable, set the value to true and kill the old rabbit docker container
echo "management_agent.disable_metrics_collector = false" >> /etc/rabbitmq/rabbitmq.conf

# The below needs to be enabled in case we have disabled the metrics collector (above)
# so that we can continue to gather queued message metrics per queue (mq_queued_messages)
# as the Prometheus plugin currently does not report individual queue totals
echo "management.enable_queue_totals = true" >> /etc/rabbitmq/rabbitmq.conf

# Required to setup ip-based clusters
RABBITMQ_NODENAME="rabbit@$($SERVICE_TOOLS_DIR/localIp.sh)"
export RABBITMQ_NODENAME
export RABBITMQ_USE_LONGNAME=true

# For network configuration docs, see, e.g., https://www.rabbitmq.com/networking.html

# Obtain the correct server port and set environment variable telling RabbitMQ
# to use it instead of its default port
export RABBITMQ_NODE_PORT=${!BOUND_PORT_DEF_RABBITMQ_SERVER_PORT}
log "Internal port: ${RABBITMQ_NODE_PORT}"

# Also obtain the internal port to use for the management UI
export RABBITMQ_MANAGEMENT_PORT_INTERNAL=${!BOUND_PORT_DEF_RABBITMQ_MANAGEMENT_UI_PORT}
log "Management port: ${RABBITMQ_MANAGEMENT_PORT_INTERNAL}"

# The monitoring port for prometheus
export RABBITMQ_MONITORING_PORT=${PORT_DEF_MONITORING_PORT}
log "Monitoring port: ${RABBITMQ_MONITORING_PORT}"

RABBITMQ_ADMIN_USER=$(get_internal_config rabbitAdminUser)
RABBITMQ_ADMIN_PASS=$(get_internal_config rabbitAdminPass)
#RABBITMQ_CONSUMER_TIMEOUT provided by plugin environment

# Update the template config file
update_config_file "${RABBITMQ_ADMIN_USER}" "${RABBITMQ_ADMIN_PASS}" "${RABBITMQ_CONSUMER_TIMEOUT}"
cat /etc/rabbitmq/rabbitmq.conf | grep -v "${RABBITMQ_ADMIN_USER}" | grep -v "${RABBITMQ_ADMIN_PASS}"

# Set port for epmd service with an environment variable (not proxied)
export ERL_EPMD_PORT=${PORT_DEF_RABBITMQ_PORT_MAPPER_DAEMON_PORT}
log "ERL_EPMD_PORT: ${ERL_EPMD_PORT}"

# Set port for distribution (not proxied)
export RABBITMQ_DIST_PORT=${PORT_DEF_RABBITMQ_DISTRIBUTION_PORT}
log "RABBITMQ_DIST_PORT: ${RABBITMQ_DIST_PORT}"

# Set port range for CLI tools (not proxied)
export RABBITMQ_CTL_DIST_PORT_MIN=${PORT_DEF_RABBITMQ_CLI_TOOLS_0_PORT}
export RABBITMQ_CTL_DIST_PORT_MAX=${PORT_DEF_RABBITMQ_CLI_TOOLS_2_PORT}
log "RABBITMQ_CTL_DIST_PORT_MIN: ${RABBITMQ_CTL_DIST_PORT_MIN}"
log "RABBITMQ_CTL_DIST_PORT_MAX: ${RABBITMQ_CTL_DIST_PORT_MAX}"

# Set the logging directory to the path managed by Foundry
export RABBITMQ_LOG_BASE=${SERVICE_LOG_DIR%%/}
log "RABBITMQ_LOG_BASE: ${RABBITMQ_LOG_BASE}"
export ERL_CRASH_DUMP="${RABBITMQ_LOG_BASE}/erl_crash.dump"
export ERL_CRASH_DUMP_SECONDS=30

# Create directories to store RabbitMQ data in the path managed by Foundry
export RABBITMQ_MNESIA_BASE=${SERVICE_DATA_DIR}rabbitmq/mnesia
mkdir -p ${RABBITMQ_MNESIA_BASE}
log "RABBITMQ_MNESIA_BASE: ${RABBITMQ_MNESIA_BASE}"

# Config file without the extension
export RABBITMQ_CONFIG_FILE=/etc/rabbitmq/rabbitmq
log "RABBITMQ_CONFIG_FILE: ${RABBITMQ_CONFIG_FILE}"

log "------------------------------"
log "Printing environment variables"
log "------------------------------"
printenv | grep -v "${RABBITMQ_ADMIN_USER}" | grep -v "${RABBITMQ_ADMIN_PASS}"

log "Current erlang version:" "$(erl -eval '{ok, Version} = file:read_file(filename:join([code:root_dir(), "releases", erlang:system_info(otp_release), "OTP_VERSION"])), io:fwrite(Version), halt().' -noshell)"

log "Setting erlang cookie"
update_erlang_cookie

log "Setting up .bashrc / aliases"
echo "alias vi='vim'" >> /root/.bashrc
echo "alias rmq='/usr/lib/rabbitmq/bin/rabbitmqctl --longnames --node=rabbit@\$(\$SERVICE_TOOLS_DIR/localIp.sh)'" >> /root/.bashrc

log "Starting cluster singleton watchdog"
SCRIPT_DIR=$( dirname "$0" )
${SCRIPT_DIR}/resetSingleton.sh &

log "Starting service"
# Start the RabbitMQ service from internal script
# /sbin/rabbitmq-server would su to rabbitmq user, which causes log permission errors
/usr/lib/rabbitmq/bin/rabbitmq-server start
