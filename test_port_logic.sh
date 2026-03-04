#!/usr/bin/env bash
# test_port_logic.sh - Stress test only the port selection algorithm

# Load the library to get gsc_port_in_use and other helpers
. /home/dablake/.local/bin/gsc_core.sh

# Source gsc_prometheus.sh but only to get its functions, not run _main
source_functions() {
    # Strip the _main call at the end
    sed '/^_main "$@"/d' /home/dablake/.local/bin/gsc_prometheus.sh | sed 's/\. "\${_gsc_lib_path}"/:/g' > /tmp/gsc_prom_funcs.sh
    source /tmp/gsc_prom_funcs.sh
}

source_functions

# Mock variables needed by the functions
_last_used_port_file="/tmp/last_used_port_test.txt"
_min_port=9090
_max_port=9599
_gsc_debug=0
_log_dir="/tmp"

test_concurrent_select() {
    local id=$1
    local lock_file="/tmp/test_port.lock"
    
    (
        flock -x 200
        # The actual logic from gsc_prometheus.sh
        local port
        port=$(_choose_free_port)
        _last_used_port=$port
        _save_last_used_port
        echo "Instance $id: Selected $port" >> /tmp/test_results.log
    ) 200>"$lock_file"
}

# 1. Start fresh
rm -f /tmp/test_results.log /tmp/last_used_port_test.txt
echo "Starting Stress Test (50 instances)..."

# 2. Launch 50 instances in background
for i in {1..50}; do
    test_concurrent_select $i &
done

wait

echo "--- Port Selection Results (First 10) ---"
head -n 10 /tmp/test_results.log | sort -k3n

echo -e "\n--- Collision Check ---"
# Check if any port appears more than once
COLLISIONS=$(awk '{print $NF}' /tmp/test_results.log | sort | uniq -c | awk '$1 > 1')
if [[ -n "$COLLISIONS" ]]; then
    echo "FAILED: Collisions detected!"
    echo "$COLLISIONS"
else
    echo "PASSED: All 50 instances received unique ports."
fi
