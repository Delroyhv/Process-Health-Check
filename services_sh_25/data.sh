#!/bin/bash

$SERVICE_TOOLS_DIR/serviceInit.sh

. ${SERVICE_PACKAGE_DIR}foundry-scripts/funcs.sh

MONITORING_PORT=$PORT_DEF_MONITORING_PORT
SUPPORT_PORT=$PORT_DEF_SUPPORT_PORT
DEBUG_PORT=$(get_debug_port)
JMX_PORT=$(get_jmx_port)

S3_HTTP_PORT=$PORT_DEF_S3_HTTP_PORT
S3_HTTPS_PORT=${!BOUND_PORT_DEF_S3_HTTPS_PORT}
S3_HTTPS_PORT_FOR_EXT_LB=$PORT_DEF_S3_HTTPS_PORT_FOR_EXT_LB

LOG4J2_CONF_DIR=$(get_logging_conf_directory)
CATALINA_OPTS="$(get_java_opts)"

# If HTTP enabled, launch Tomcat using HTTP enabled xml
ENABLE_HTTP_PORT=${ENABLE_HTTP}
if [ "$ENABLE_HTTP_PORT" = true ]
then
    ln -sf $CATALINA_HOME/conf/http_enabled_server.xml $CATALINA_HOME/conf/server.xml
else
    ln -sf $CATALINA_HOME/conf/http_disabled_server.xml $CATALINA_HOME/conf/server.xml
fi

# Redirect error logs
outlog="$SERVICE_LOG_DIR/data-service.stdout"
errlog="$SERVICE_LOG_DIR/data-service.stderr"

redirect_to_log_int "$outlog" "$errlog"

# Download foundry cluster private key and certificate
PKCS_FILE=/etc/tomcat/cluster.pkcs12
downloadSslWithRetry $PKCS_FILE
dlStatus=$?
if [[ $dlStatus != 0 ]] ; then
    echo "Failed to download $PKCS_FILE: $dlStatus. Exiting."
    exit $dlStatus
fi

# Create tomcat temp dir for multipart POST data (see S3Servlet.java)
TOMCAT_TMP="$SERVICE_DATA_DIR/tomcat-tmp"
rm -rf "$TOMCAT_TMP"
mkdir -p "$TOMCAT_TMP"

# Update web.xml
TOMCAT_WEB_XML="/etc/tomcat/web.xml"
sed -i -e "s#CLUSTERNAME#${CLUSTER_NAME,,}#" ${TOMCAT_WEB_XML}

CATALINA_OPTS="$CATALINA_OPTS -Dhttp.max_request_headers=${MAX_HTTP_REQUEST_HEADERS:-100}"
CATALINA_OPTS="$CATALINA_OPTS -Dssl.protocols=${SSL_PROTOCOLS}"
CATALINA_OPTS="$CATALINA_OPTS -Dssl.ciphers=${SSL_CIPHERS}"
CATALINA_OPTS="$CATALINA_OPTS -Ds3.clustername=s3.${CLUSTER_NAME,,}"
/opt/aspen/scripts/start-tomcat.sh "$LOG4J2_CONF_DIR" "$CATALINA_OPTS" "$MONITORING_PORT" "$SUPPORT_PORT" "$DEBUG_PORT" "$S3_HTTP_PORT" "$S3_HTTPS_PORT" "$S3_HTTPS_PORT_FOR_EXT_LB" "$JMX_PORT"
