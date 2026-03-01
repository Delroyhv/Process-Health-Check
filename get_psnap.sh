#!/bin/bash

psnap_name=$(find cluster_triage | grep Prometheus) 
if [[ ! -f $psnap_name ]]; then
    echo "ERROR: cannot find Prometheus psnap file"
    exit 1
fi

psnap_date=$(echo "$psnap_name" | awk -F"_" '{ print $(NF-2) "_" $(NF-1) }')
echo "name=$psnap_name"
echo "date=$psnap_date"
new_psnap_name="psnap_${psnap_date}.tar.xz"
echo "new=$new_psnap_name"
mv ${psnap_name} ${new_psnap_name}
#tar Jxvf ${new_psnap_name}
