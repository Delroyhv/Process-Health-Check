#!/usr/bin/env bash
# test_concurrency.sh - Stress test gsc_prometheus port selection

# 1. Cleanup everything first
echo "[TEST] Cleaning up old containers..."
sudo /home/dablake/.local/bin/gsc_prometheus.sh --cleanup --override=y -b . >/dev/null 2>&1

BARRIER_FILE="/tmp/gsc_test_barrier.lock"
SNAP_FILE="/ci/05455380/2026-02-23_17-04-47/psnap_2026-Feb-23_11-53-12.tar.xz"

# Function to run a single instance that waits for the barrier
run_instance() {
    local id=$1
    (
        # This flock waits for the main script to release the barrier
        flock -s 201 
        sudo /home/dablake/.local/bin/gsc_prometheus.sh \
            -c "User_$id" \
            -s "SR_$id" \
            -f "$SNAP_FILE" \
            -b . --replace > "/tmp/gsc_test_$id.log" 2>&1
    ) 201>"$BARRIER_FILE"
}

# Hold the barrier lock
exec 201>"$BARRIER_FILE"
flock -x 201

echo "[TEST] Launching 3 concurrent instances..."
run_instance 1 &
run_instance 2 &
run_instance 3 &

sleep 1
echo "[TEST] GO! (Releasing barrier)"
flock -u 201

# Progress Spinner
spin='-\|/'
echo -n "[TEST] Processing background tasks... "
while kill -0 $! 2>/dev/null; do
  for i in {0..3}; do
    echo -ne "\b${spin:$i:1}"
    sleep 0.1
  done
done
echo -ne "\bDone!\n"

# Wait for them to finish properly
wait

echo -e "\n[TEST] Results (Podman Status):"
podman ps --format '{{.Names}} -> {{.Ports}}' | grep "gsc_prometheus" | sort

for id in 1 2 3; do
    PORT=$(grep 'started on port' "/tmp/gsc_test_$id.log" | awk '{print $NF}' | tr -d '.')
    echo "[Instance $id] Assigned Port: ${PORT:-FAILED}"
done

echo -e "\n[TEST] Final Port Tracking State:"
cat /var/log/gsc_prometheus/v1.8.31/last_used_port.txt
