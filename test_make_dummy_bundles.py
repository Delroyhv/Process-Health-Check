#!/usr/bin/env python3
"""
test_make_dummy_bundles.py
Generate three synthetic HCP Cloud Scale support bundles for CI testing.

Bundles are placed in /ci/<SR>/ as supportLogs_<ts>.tar.<date>.xz files.
All data is synthetic: fake IPs, company names, serial numbers.

Bundle 1 — SR 11223344 / Datanode Corp   : clean cluster, all OK       (8 nodes)
Bundle 2 — SR 55667788 / Pinnacle Systems: warnings (mem/partitions)   (7 nodes)
Bundle 3 — SR 99001122 / Galactic Storage: critical (mem/partitions)   (11 nodes)
"""

import json
import os
import subprocess
import sys
import tarfile
import tempfile
import uuid
from datetime import datetime, timedelta
from pathlib import Path

CI_DIR = Path("/ci")
BUNDLE_TS = "2026-03-15_10-00-00"   # fake collection timestamp
BUNDLE_DATE = "20260315"
BUNDLE_TIME = "0900"

# ---------------------------------------------------------------------------
# Scenarios
# ---------------------------------------------------------------------------
BUNDLES = [
    {
        "sr":        "11223344",
        "company":   "Datanode Corp",
        "cluster":   "hcpcs01.datanode-corp.net",
        "serial":    "SHCA110099001",
        "version":   "2.6.1.65",
        "cs_version": "2.6",
        "node_ips":  [f"10.10.1.{n}" for n in range(11, 19)],    # 8 nodes
        "ram_gb":    256,
        "leaders_per_node": 300,    # copies/node = 300*3=900, OK — below 1000 threshold
        "scenario":  "good",
        "overprotected": 0,
        "underprotected": 0,
        "unprotected": 0,
        "orphaned": 0,
        "leaderless": 0,
        "mem_values": {            # all within memcheck.conf bounds
            "Cassandra":             "2500",
            "Chronos":               "800",
            "Data-Lifecycle":        "8100",
            "Elasticsearch":         "8100",
            "Grafana":               "800",
            "Kafka":                 "2050",
            "Key-Management-Server": "2050",
            "Logstash":              "800",
            "MAPI-Gateway":          "900",
            "Message-Queue":         "8100",
            "Metadata-Cache":        "900",
            "Metadata-Coordination": "2050",
            "Metadata-Gateway":      "100000",
            "Metrics":               "4050",
            "Mirror-In-Policy":      "1050",
            "Mirror-Out-Policy":     "1050",
            "Policy-Engine":         "4050",
            "S3-Gateway":            "18000",
            "S3-Notifications":      "800",
            "Tracing-Agent":         "2050",
            "Tracing-Collector":     "2050",
            "Tracing-Query":         "800",
        },
    },
    {
        "sr":        "55667788",
        "company":   "Pinnacle Systems",
        "cluster":   "hcpcs01.pinnacle-systems.io",
        "serial":    "SHCA220099002",
        "version":   "2.5.0.8",
        "cs_version": "2.5",
        "node_ips":  [f"10.20.2.{n}" for n in range(21, 28)],    # 7 nodes
        "ram_gb":    128,
        "leaders_per_node": 400,    # copies/node = 400*3=1200, WARNING — >1000 but <1500
        "scenario":  "warning",
        "overprotected": 24,
        "underprotected": 0,
        "unprotected": 0,
        "orphaned": 3,
        "leaderless": 0,
        "mem_values": {            # several services > max (warning; none > max*2)
            "Cassandra":             "3500",     # max 2600; 3500 < 5200 → WARNING
            "Chronos":               "1300",     # max 1000; 1300 < 2000 → WARNING
            "Data-Lifecycle":        "8100",
            "Elasticsearch":         "8100",
            "Grafana":               "800",
            "Kafka":                 "2050",
            "Key-Management-Server": "2800",     # max 2100; 2800 < 4200 → WARNING
            "Logstash":              "1500",     # max 1000; 1500 < 2000 → WARNING
            "MAPI-Gateway":          "900",
            "Message-Queue":         "8100",
            "Metadata-Cache":        "900",
            "Metadata-Coordination": "2050",
            "Metadata-Gateway":      "100000",
            "Metrics":               "4050",
            "Mirror-In-Policy":      "1050",
            "Mirror-Out-Policy":     "1050",
            "Policy-Engine":         "4050",
            "S3-Gateway":            "18000",
            "S3-Notifications":      "1500",    # max 1000; 1500 < 2000 → WARNING
            "Tracing-Agent":         "2800",    # max 2100; 2800 < 4200 → WARNING
            "Tracing-Collector":     "2050",
            "Tracing-Query":         "800",
        },
    },
    {
        "sr":        "99001122",
        "company":   "Galactic Storage",
        "cluster":   "hcpcs01.galactic-storage.com",
        "serial":    "SHCA330099003",
        "version":   "2.4.0.3",
        "cs_version": "2.4",
        "node_ips":  [f"10.30.3.{n}" for n in range(31, 42)],   # 11 nodes
        "ram_gb":    512,
        "leaders_per_node": 700,    # copies/node = 700*3=2100, CRITICAL — >2000
        "scenario":  "critical",
        "overprotected": 120,
        "underprotected": 45,
        "unprotected": 12,
        "orphaned": 8,
        "leaderless": 3,
        "mem_values": {            # several services > max*2 → ERROR
            "Cassandra":             "10000",    # max 2600; 10000 > 5200 → ERROR
            "Chronos":               "1424",     # max 1000; 1424 < 2000 → WARNING
            "Data-Lifecycle":        "8100",
            "Elasticsearch":         "20480",    # max 8200; 20480 > 16400 → ERROR
            "Grafana":               "20480",    # max 1000; 20480 > 2000 → ERROR
            "Kafka":                 "10000",    # max 2100; 10000 > 4200 → ERROR
            "Key-Management-Server": "2800",     # max 2100; 2800 < 4200 → WARNING
            "Logstash":              "5000",     # max 1000; 5000 > 2000 → ERROR
            "MAPI-Gateway":          "10000",    # max 1000; 10000 > 2000 → ERROR
            "Message-Queue":         "8100",
            "Metadata-Cache":        "900",
            "Metadata-Coordination": "8192",     # max 2100; 8192 > 4200 → ERROR
            "Metadata-Gateway":      "100000",
            "Metrics":               "4050",
            "Mirror-In-Policy":      "24000",    # max 1100; 24000 > 2200 → ERROR
            "Mirror-Out-Policy":     "24000",    # max 1100; 24000 > 2200 → ERROR
            "Policy-Engine":         "4050",
            "S3-Gateway":            "65000",    # max 20000; 65000 > 40000 → ERROR
            "S3-Notifications":      "10000",    # max 1000; 10000 > 2000 → ERROR
            "Tracing-Agent":         "2050",
            "Tracing-Collector":     "2050",
            "Tracing-Query":         "2048",     # max 1000; 2048 > 2000 → ERROR
        },
    },
]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def make_uuid():
    return str(uuid.uuid4())


def node_uuid_map(node_ips):
    """Return {ip: uuid} mapping for each node."""
    return {ip: make_uuid() for ip in node_ips}


def build_partition_map_json(node_ips, node_uuids, leaders_per_node):
    """Build a single partitionMap*.json source file.

    Each node IP gets `leaders_per_node` partitions where it is leader
    (first in nodesLeaderFirst). Remaining 2 replicas cycle over other nodes.
    Returns a dict matching the real partitionMap file structure.
    """
    n = len(node_ips)
    entry_mapping = {}
    pid = 0
    for i, leader_ip in enumerate(node_ips):
        for _ in range(leaders_per_node):
            # Pick 2 follower nodes (different from leader, cycling)
            followers = [node_ips[(i + 1 + f) % n] for f in range(2)]
            nodes_leader_first = [
                {"nodeId": node_uuids[leader_ip], "connectionUrl": f"{leader_ip}:12500", "awareOfGroup": True},
            ] + [
                {"nodeId": node_uuids[fp], "connectionUrl": f"{fp}:12500", "awareOfGroup": True}
                for fp in followers
            ]
            entry_mapping[str(pid)] = {
                "partitionId": pid,
                "leaderId": node_uuids[leader_ip],
                "nodesLeaderFirst": nodes_leader_first,
                "keySpaceRanges": [{"keySpace": {}}],
                "entryOrder": {"currentTerm": 100 + pid, "currentLifeTimeOrder": 1},
            }
            pid += 1
    return {
        "entryMapping": entry_mapping,
        "partitionMapping": {"keySpaceTreeMap": {}},
    }


def build_partition_state_json(node_ips, node_uuids, leaders_per_node, total_partitions):
    """Build a clusterPartitionState*.json source file (object keyed by pid string)."""
    state = {}
    pid = 0
    n = len(node_ips)
    for i, leader_ip in enumerate(node_ips):
        for _ in range(leaders_per_node):
            followers = [node_ips[(i + 1 + f) % n] for f in range(2)]
            state[str(pid)] = {
                "nodes": [node_uuids[leader_ip]] + [node_uuids[fp] for fp in followers],
                "partitionSize": 2_000_000 + pid * 1000,
                "isLeaderAvailable": True,
                "keySpaceId": 15,
                "start": [],
                "end": [],
                "partitionId": pid,
                "isLeader": True,
            }
            pid += 1
    return state


def build_partition_split_json(node_ips, num_splits=200):
    """Generate NDJSON partition split history spanning 12 months."""
    lines = []
    base_date = datetime(2025, 3, 1)
    pid = 1_000_000
    for i in range(num_splits):
        dt = base_date + timedelta(days=int(i * 365 / num_splits))
        date_str = dt.strftime("%b %-d, %Y, %-I:%M:%S %p")
        leader_ip = node_ips[i % len(node_ips)]
        lines.append(json.dumps({
            "date": date_str,
            "parentId": pid + i * 2,
            "firstChildId": pid + i * 2 + 100_000,
            "secondChildId": pid + i * 2 + 200_000,
            "leaderNodeInfo": leader_ip,
        }))
    return "\n".join(lines) + "\n"


def build_services_json(svc_mem, node_ips):
    """Build services.json with configProperties mem values."""
    services = []
    for name, mem in svc_mem.items():
        services.append({
            "name": name,
            "config": {
                "propertyGroups": [{
                    "name": "main",
                    "configProperties": [
                        {
                            "modelVersion": "1.1.0",
                            "name": "mem",
                            "type": "text",
                            "userVisibleName": "Container Memory",
                            "userVisibleDescription": "Hard memory limit for the docker container.",
                            "required": True,
                            "value": str(mem),
                        }
                    ],
                }],
            },
        })
    # Build minimal instances list
    instances = []
    for i, ip in enumerate(node_ips):
        instances.append({
            "nodeId": f"node-{i+1:02d}",
            "hostname": f"cs{i+1:02d}",
            "ip": ip,
            "services": list(svc_mem.keys()),
        })
    return {
        "modelVersion": "1.2.0",
        "serviceConfigs": services,
        "instances": instances,
    }


def build_partition_info_tool_out(node_ips, node_uuids, leaders_per_node,
                                  overprotected, underprotected, unprotected,
                                  orphaned, leaderless, cluster):
    """Build the partition_info_tool output file for get_partition_details.sh."""
    total = leaders_per_node * len(node_ips)
    # Each node holds 3 copies per leader partition (leader once + follower twice, uniform distribution)
    copies_per_node = leaders_per_node * 3
    lines = []
    lines.append(f"# partition_info_tool.sh, version 1.1.4, -d -m -p -- {BUNDLE_DATE}")
    lines.append(f"Collecting output for partitionMap API from Metadata-Coordination instance(s):")
    lines.append(f"{len(node_ips)} (OK)")
    lines.append("")
    lines.append("###### clusterPartitioState #######")
    lines.append(f"## /opt/hcpcs/hcpcsSupport/supportLogs/cluster_triage/{cluster}/cluster_MAPI_infos/clusterPartitionState_Metadata-Coordination_{node_ips[0]}.json:")
    lines.append("Count of partition copies / instance:")
    for ip in node_ips:
        lines.append(f"   {copies_per_node} Node_IP: {ip}:12500,")
    lines.append("")
    lines.append(f"Count of partitions: {total}")
    lines.append("")
    lines.append("Count of copies per partition:")
    lines.append(f"   {total} \"partitions have 3 copies.\"")
    lines.append("")
    lines.append("Partitions without leader (isLeaderAvailable=false): 0")
    lines.append("")
    lines.append("")
    lines.append("###### partitionState protection analysis #######")
    if overprotected == 0 and underprotected == 0 and unprotected == 0:
        lines.append("No over- or under-protected partitions found.")
    else:
        if overprotected > 0:
            lines.append(f"Found {overprotected} over-protected partitions.")
        if underprotected > 0:
            lines.append(f"Found {underprotected} under-protected partitions.")
        if unprotected > 0:
            lines.append(f"Found {unprotected} un-protected partitions.")
    lines.append("")
    lines.append("")
    lines.append("###### partitionMap Metadata-Coordination #######")
    lines.append(f"## /opt/hcpcs/hcpcsSupport/supportLogs/cluster_triage/{cluster}/cluster_MAPI_infos/partitionMap_Metadata-Coordination_{node_ips[0]}.json:")
    lines.append("Count of partition copies / node, instance:")
    for i, ip in enumerate(node_ips):
        lines.append(f"   {copies_per_node} Node_IP: {ip}:12500, MDGW_ID: {node_uuids[ip]}")
    lines.append("")
    lines.append("Leadercount / node, instance:")
    for i, ip in enumerate(node_ips):
        lines.append(f"   {leaders_per_node} Node_IP: {ip}:12500, MDGW_ID: {node_uuids[ip]}")
    lines.append("")
    lines.append(f"Count of partitions: {total}")
    lines.append("")
    lines.append("Count of copies per partition:")
    lines.append(f"   {total} partitions have 3 copies.")
    lines.append("")
    lines.append("")
    lines.append("###### partitionState bad partitions analysis #######")
    lines.append(f"## /opt/hcpcs/hcpcsSupport/supportLogs/cluster_triage/{cluster}/cluster_MAPI_infos/clusterPartitionState_Metadata-Coordination_{node_ips[0]}.json:")
    lines.append("")
    if overprotected > 0:
        lines.append(f"Found {overprotected} partitions which are affected by overprotection.")
        for pid in range(1, min(overprotected + 1, 6)):
            lines.append(f" partition {pid * 1000}: copies=4 expected=3")
    else:
        lines.append("No partitions found which are affected by overprotection.")
    lines.append("")
    if underprotected > 0:
        lines.append(f"Found {underprotected} partitions which are affected by underprotection.")
        for pid in range(1, min(underprotected + 1, 4)):
            lines.append(f" partition {pid * 2000}: copies=2 expected=3")
    else:
        lines.append("No partitions found which are affected by underprotection.")
    lines.append("")
    if unprotected > 0:
        lines.append(f"Found {unprotected} partitions which are affected by unprotection.")
        for pid in range(1, min(unprotected + 1, 3)):
            lines.append(f" partition {pid * 3000}: copies=0 expected=3")
    else:
        lines.append("No partitions found which are affected by unprotection.")
    lines.append("")
    if orphaned > 0:
        lines.append(f"Found {orphaned} partitions which are orphaned.")
    else:
        lines.append("No partitions found which are orphaned.")
    lines.append("")
    if leaderless > 0:
        lines.append(f"Found {leaderless} partitions which are leaderless.")
    else:
        lines.append("No partitions found which are leaderless.")
    lines.append("")
    return "\n".join(lines) + "\n"


def build_lshw_out(node_ip, hostname, ram_gb):
    """Build a minimal lshw-style output for one node."""
    ram_mib = ram_gb * 1024
    return f"""\
=== {hostname} ===
*-memory
     description: System Memory
     size: {ram_mib}MiB ({ram_gb}GiB)
*-cpu
     description: Central Processor
     product: Intel Xeon Gold 6234
     width: 64 bits
"""


def build_top_out(node_ip, hostname):
    """Build minimal top output."""
    return f"""\
top - 10:00:00 up 120 days,  3:42,  1 user,  load average: 0.45, 0.51, 0.48
Tasks: 312 total,   1 running, 311 sleeping,   0 stopped,   0 zombie
%Cpu(s):  3.2 us,  0.8 sy,  0.0 ni, 95.8 id,  0.1 wa,  0.0 hi,  0.1 si
MiB Mem : 261120.0 total, 180000.1 free,  45000.3 used,  36119.6 buff/cache
MiB Swap:   8192.0 total,   8192.0 free,      0.0 used. 210000.0 avail Mem
"""


def build_df_out(node_ip, hostname):
    """Build df -h style output for a node."""
    return """\
Filesystem      Size  Used Avail Use% Mounted on
/dev/sda1        50G   15G   35G  30% /
/dev/sda2       200G   40G  160G  20% /data
tmpfs            64G     0   64G   0% /dev/shm
"""


def build_meminfo_out(ram_gb):
    """Build /proc/meminfo output."""
    ram_kb = ram_gb * 1024 * 1024
    free_kb = int(ram_kb * 0.65)
    return f"""\
MemTotal:       {ram_kb} kB
MemFree:        {free_kb} kB
MemAvailable:   {free_kb} kB
Buffers:            65536 kB
Cached:           1048576 kB
SwapTotal:        8388608 kB
SwapFree:         8388608 kB
"""


# ---------------------------------------------------------------------------
# Bundle builder
# ---------------------------------------------------------------------------

def build_bundle(bundle, tmpdir):
    """Build all files for one bundle in tmpdir. Returns list of (arcpath, localpath)."""
    sr = bundle["sr"]
    company = bundle["company"]
    cluster = bundle["cluster"]
    serial = bundle["serial"]
    version = bundle["version"]
    node_ips = bundle["node_ips"]
    ram_gb = bundle["ram_gb"]
    leaders_per_node = bundle["leaders_per_node"]
    mem_values = bundle["mem_values"]

    node_uuids = node_uuid_map(node_ips)
    total_parts = leaders_per_node * len(node_ips)

    files = {}  # arcname → content (str or bytes)

    # Files are at the root of the tar (no top-level timestamp dir),
    # matching the real bundle format: cluster_triage/... not <ts>/cluster_triage/...

    # healthcheck.conf at root level so runchk.sh picks up _cs_version
    cs_ver = bundle["cs_version"]
    files["healthcheck.conf"] = (
        f'#Health Check Configuration file Version 2\n'
        f'#HCP CS version 2.5 or 2.6\n'
        f'_cs_version="{cs_ver}"\n'
        f'_prom_server=""\n'
        f'_prom_port="9090"\n'
        f'_prom_time_stamp=""\n'
        f'_install_dir="/usr/local/bin/"\n'
    )

    # cluster_triage / cluster_MAPI_infos
    mapi_base = f"cluster_triage/{cluster}/cluster_MAPI_infos"

    files[f"{mapi_base}/cluster.name"] = cluster + "\n"
    files[f"{mapi_base}/cluster.serial"] = serial + "\n"
    files[f"{mapi_base}/setup.json"] = json.dumps({
        "productVersion": version,
        "clusterName": cluster,
        "clusterSerialNumber": serial,
    }, indent=2) + "\n"

    # services.json
    svc_json = build_services_json(mem_values, node_ips)
    files[f"{mapi_base}/services.json"] = json.dumps(svc_json, indent=2) + "\n"

    # Watchdog.iplist.external
    files[f"{mapi_base}/Watchdog.iplist.external"] = "\n".join(node_ips) + "\n"

    # partitionMap source files (one per node, matches *map*.json)
    for i, ip in enumerate(node_ips):
        fname = f"partitionMap_Metadata-Gateway_{ip}.json"
        pm = build_partition_map_json(node_ips, node_uuids, leaders_per_node)
        files[f"{mapi_base}/{fname}"] = json.dumps(pm) + "\n"

    # clusterPartitionState source file (matches *State*.json)
    ps = build_partition_state_json(node_ips, node_uuids, leaders_per_node, total_parts)
    ps_fname = f"clusterPartitionState_Metadata-Coordination_{node_ips[0]}.json"
    files[f"{mapi_base}/{ps_fname}"] = json.dumps(ps) + "\n"

    # collect_healthcheck_data / logs
    logs_base = f"cluster_triage/{cluster}/collect_healthcheck_data/2026_03_15_09_00_00/logs"

    pit_content = build_partition_info_tool_out(
        node_ips, node_uuids, leaders_per_node,
        bundle["overprotected"], bundle["underprotected"],
        bundle["unprotected"], bundle["orphaned"], bundle["leaderless"],
        cluster,
    )
    files[f"{logs_base}/0367_40_partition_info_tool_MDCO_MDGW_DLS_PARTITION_DETAILS.out"] = pit_content

    # collect_healthcheck_data / collected_output_files
    out_base = f"cluster_triage/{cluster}/collect_healthcheck_data/2026_03_15_09_00_00/collected_output_files"

    # splitpartition.json (one file from node cs01)
    split_ndjson = build_partition_split_json(node_ips, num_splits=300)
    split_fname = f"node_info_cs01.{cluster}_2026-Mar-15_09-00-00_1_productinfo_splitpartition.json"
    files[f"{out_base}/{split_fname}"] = split_ndjson

    # per-node files
    for i, ip in enumerate(node_ips):
        hostname = f"cs{i+1:02d}.{cluster}"
        short = f"cs{i+1:02d}"
        ts_tag = "2026-Mar-15_09-00-00"
        node_prefix = f"node_info_{short}.{cluster}_{ts_tag}_1"

        files[f"{out_base}/{node_prefix}_systeminfo_lshw.out"] = build_lshw_out(ip, hostname, ram_gb)
        files[f"{out_base}/{node_prefix}_node_system_top.out"] = build_top_out(ip, hostname)
        files[f"{out_base}/{node_prefix}_systeminfo_proc-meminfo.out"] = build_meminfo_out(ram_gb)
        files[f"{out_base}/{node_prefix}_diskinfo_df-h.out"] = build_df_out(ip, hostname)

    return files


def write_bundle(bundle, dest_dir):
    sr = bundle["sr"]
    print(f"\n[{sr}] Building bundle for {bundle['company']} ({bundle['scenario']})...")

    with tempfile.TemporaryDirectory() as tmpdir:
        files = build_bundle(bundle, tmpdir)

        # Write files to tmpdir
        file_paths = {}
        for arcname, content in files.items():
            local = Path(tmpdir) / arcname
            local.parent.mkdir(parents=True, exist_ok=True)
            if isinstance(content, bytes):
                local.write_bytes(content)
            else:
                local.write_text(content, encoding="utf-8")
            file_paths[arcname] = local

        # Create tar.xz
        tar_name = f"supportLogs_{BUNDLE_TS}_synthetic.tar.{BUNDLE_DATE}.{BUNDLE_TIME}.xz"
        tar_path = dest_dir / tar_name

        with tarfile.open(tar_path, "w:xz") as tar:
            for arcname, local in sorted(file_paths.items()):
                tar.add(local, arcname=arcname)

        size_mb = tar_path.stat().st_size / 1_048_576
        print(f"[{sr}] Created {tar_path} ({size_mb:.1f} MB, {len(files)} files)")
        return tar_path


def main():
    # Optional SR filter from args
    filter_srs = set(sys.argv[1:]) if len(sys.argv) > 1 else None

    for bundle in BUNDLES:
        sr = bundle["sr"]
        if filter_srs and sr not in filter_srs:
            continue

        dest_dir = CI_DIR / sr
        dest_dir.mkdir(parents=True, exist_ok=True)

        # Remove any pre-existing synthetic bundle for this SR
        for old in dest_dir.glob("supportLogs_*_synthetic.tar.*.xz"):
            old.unlink()
            print(f"[{sr}] Removed old synthetic bundle: {old.name}")

        # Remove any pre-existing extracted dirs from prior runs
        for old_dir in dest_dir.glob("2026-03-15_10-00-00"):
            import shutil
            shutil.rmtree(old_dir, ignore_errors=True)
            print(f"[{sr}] Removed old extracted dir: {old_dir.name}")

        write_bundle(bundle, dest_dir)

    print("\nAll synthetic bundles created.")
    print("Run: sudo bash test_battery.sh 11223344 55667788 99001122")


if __name__ == "__main__":
    main()
