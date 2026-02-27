#!/usr/bin/env bash
# allow failures early in a pipeline to propagate back to
#  the shell.  this doesn't happen by default
set -o pipefail

# more great ideas from http://kvz.io/blog/2013/11/21/bash-best-practices/
# See here for in-depth study: http://www.tldp.org/LDP/abs/html/index.html
set -o errexit
set -o nounset

# logs to stdout
log () {
    echo "$(date -u) $*"
}

# logs to stderr
logError () {
    echo "$(date -u) $*" >&2
}

enforce_root() {
    if [ "$(id -u)" != "0" ]
    then
        echo "This script must be run as root" 1>&2
        exit 1
    fi
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

# escape spaces in a string. echos the modified string. (capture with $())
escape_spaces () {
    local input=$1
    echo $input | sed -e "s# #\\\\\ #g"
}

rotate_log () {
    local filename="$1"
    local TIMESTAMP
    TIMESTAMP=$(date -u +%F-%R:%S)
    if [ -s "$filename" ]
    then
        mv "$filename" "$filename.$TIMESTAMP"
    fi
}

redirect_to_log_int () {
    local outlog=$1
    local errlog=$2

    rotate_log "$outlog"
    rotate_log "$errlog"

    exec 1>> "$outlog"
    exec 2>> "$errlog"
}
