#!/usr/bin/env bash
# Common configuration and methods for services


# allow failures early in a pipeline to propagate back to
#  the shell.  this doesn't happen by default
set -o pipefail

# more great ideas from http://kvz.io/blog/2013/11/21/bash-best-practices/
# See here for in-depth study: http://www.tldp.org/LDP/abs/html/index.html
set -o errexit
set -o nounset

# set -v

CONFIG_PATH="$SERVICE_TOOLS_CONFIG_DIR/cluster.config"

ZK_BUFFER_SIZE="-Djute.maxbuffer=4194304"

#redirects standard out and standard error to files that get auto-rotated.
# log/$container/$logfile.std{out|err}
redirect_to_log () {
    local logfile=$1

    local outlog="$SERVICE_LOG_DIR/$logfile.stdout"
    local errlog="$SERVICE_LOG_DIR/$logfile.stderr"

    redirect_to_log_int "$outlog" "$errlog"
}

source "$SERVICE_PACKAGE_DIR/svcbin/common.sh"
