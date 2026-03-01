#!/usr/bin/env bash
COPY_FROM="."
COPY_TO="./beta"

cp ${COPY_FROM}/runchk.sh ${COPY_TO}/
cp ${COPY_FROM}/chk_cluster.sh ${COPY_TO}/
cp ${COPY_FROM}/parse_instances_info.sh ${COPY_TO}/
cp ${COPY_FROM}/prep_services_instances.sh ${COPY_TO}/
cp ${COPY_FROM}/chk_alerts.sh ${COPY_TO}/
cp ${COPY_FROM}/chk_services_sh.sh ${COPY_TO}/
cp ${COPY_FROM}/chk_snodes.sh ${COPY_TO}/
cp ${COPY_FROM}/chk_services_memory.sh ${COPY_TO}/
cp ${COPY_FROM}/chk_partInfo.sh ${COPY_TO}/
cp ${COPY_FROM}/parse_partInfo_keyspaces.sh ${COPY_TO}/
cp ${COPY_FROM}/parse_map_ranges.sh ${COPY_TO}/
cp ${COPY_FROM}/parse_services_memory.sh ${COPY_TO}/
cp ${COPY_FROM}/detect_app_per_bucket.sh ${COPY_TO}/
cp ${COPY_FROM}/insert_sizes_1dir.sh ${COPY_TO}/
cp ${COPY_FROM}/hcpcs_parse_partitions_map.sh ${COPY_TO}/
cp ${COPY_FROM}/hcpcs_parse_partitions_state.sh ${COPY_TO}/
cp ${COPY_FROM}/hcpcs_lib.sh ${COPY_TO}/
cp ${COPY_FROM}/memcheck.conf ${COPY_TO}/
