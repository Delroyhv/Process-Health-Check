#!/bin/bash

$SERVICE_TOOLS_DIR/serviceInit.sh

. ${SERVICE_PACKAGE_DIR}foundry-scripts/funcs.sh

DEBUG_PORT=$(get_debug_port)
DEBUG_OPTS=$(get_debug_options $DEBUG_PORT)
LOG4J2_CONF_DIR=$(get_logging_conf_directory)

# Redirect error logs
outlog="$SERVICE_LOG_DIR/vault.stdout"
errlog="$SERVICE_LOG_DIR/vault.stderr"


redirect_to_log_int "$outlog" "$errlog"


##### AFTER HERE IS WHERE YOU ADD THE CODE TO START YOUR SERVICE #####

VAULT_CONFIG_FILE="/etc/vault/server.hcl"
VAULT_HOST=$($SERVICE_TOOLS_DIR/localIp.sh)
ZOOKEEPER_HOST=$($SERVICE_TOOLS_DIR/zookeeperUrl.sh "")

VAULT_HTTP_PORT=${!BOUND_PORT_DEF_VAULT_HTTP_PORT}
VAULT_CLUSTER_PORT=${PORT_DEF_VAULT_CLUSTER_PORT}

# Download foundry cluster private key and certificate
PKCS_FILE=/etc/vault/cluster.pkcs12
PRIVATE_KEY_FILE=/etc/vault/cluster.key
CERT_FILE=/etc/vault/cluster.crt

downloadSslWithRetry $PKCS_FILE
dlStatus=$?
if [[ $dlStatus != 0 ]] ; then
    echo "Failed to download $PKCS_FILE: $dlStatus. Exiting."
    exit $dlStatus
fi

openssl pkcs12 -nodes -in $PKCS_FILE -passin pass: -nocerts -out $PRIVATE_KEY_FILE
openssl pkcs12 -nodes -in $PKCS_FILE -passin pass: -nokeys -out $CERT_FILE

# Update config file
sed -i -e "s#VAULT_HOST#${VAULT_HOST}#" \
    -e "s#VAULT_HTTP_PORT#${VAULT_HTTP_PORT}#" \
    -e "s#VAULT_CLUSTER_PORT#${VAULT_CLUSTER_PORT}#" \
    -e "s#ZOOKEEPER_HOST#${ZOOKEEPER_HOST}#" \
    -e "s#VAULT_CERT_FILE#${CERT_FILE}#" \
    -e "s#VAULT_KEY_FILE#${PRIVATE_KEY_FILE}#" \
    ${VAULT_CONFIG_FILE}

echo "Vault config:"
cat ${VAULT_CONFIG_FILE}

# Run vault server
vault server -config ${VAULT_CONFIG_FILE}
