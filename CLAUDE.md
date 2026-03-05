# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A health check and monitoring toolkit for **HCP Cloud Scale** (Hitachi Vantara) clusters. Processes support logs and Prometheus snapshots to surface errors, warnings, memory anomalies, and partition issues.

## Development Commands

```bash
make bash-n     # Syntax check all .sh files (bash -n)
make lint       # Run shellcheck on all .sh files
make bundle     # Create release tar.xz (also updates README version)
make docs       # Generate docs/ (Markdown + PDF) from man pages
```

To rebuild the `partition_growth` Go binary:
```bash
cd partition_growth && make all
```

## Architecture

### Entry Points

| Script | Role |
|--------|------|
| `gsc_healthcheck.sh` | End-to-end orchestrator: expands support bundle → starts Prometheus → runs `runchk.sh` |
| `runchk.sh` | Sequentially runs all `chk_*.sh` and `print_*.sh` checks, summarizes ERRORs/WARNINGs |
| `gsc_prometheus.sh` | Extracts a `psnap_*.tar.xz` and runs Prometheus in a Docker/Podman container |
| `gsc_grafana.sh` | Runs Grafana with provisioned HCP dashboards |
| `selfcheck.sh` | Validates all dependencies and required files (run at start of `runchk.sh`) |

### Shared Libraries

- **`gsc_core.sh`** — The single source of truth for all shared functions. All scripts source this. Contains: strict mode, logging (`gsc_log_*`), dependency checks (`gsc_require`), container engine abstraction, temp dir management, JSON helpers, partition artifact handling, and secure `sudo` vault management.
- **`gsc_library.sh`** — Thin compatibility shim that simply sources `gsc_core.sh`. Kept for backward compatibility.

**Rule:** All common/reusable functions must be placed in `gsc_core.sh`, not duplicated in individual scripts.

### Check Scripts (`chk_*.sh`)

Each check script focuses on one diagnostic area. They are invoked by `runchk.sh` in sequence:

- `chk_metrics.sh` — Queries Prometheus using definitions from `hcpcs_hourly_alerts.json` / `hcpcs_daily_alerts.json`
- `chk_services_memory.sh` — Validates service RSS memory against bounds in `memcheck.conf`
- `chk_collected_metrics.sh` — Validates quality of pre-collected metrics
- `chk_filesystem.sh`, `chk_disk_perf.sh`, `chk_partInfo.sh`, etc. — Filesystem/disk diagnostics
- `chk_cluster.sh`, `chk_snodes.sh` — Cluster state checks
- `chk_docker.sh`, `chk_chrony.sh`, `chk_top.sh`, `chk_messages.sh` — System-level checks

### Service Version Directories

`services_sh_25/` and `services_sh_26/` contain HCP software version-specific service scripts (v2.5 and v2.6). Scripts in these directories are sourced based on `_cs_version` from `healthcheck.conf`.

### Go Components

- **`partition_growth/main.go`** — Analyzes partition growth trends from JSON event data. Pre-compiled binaries in `partition_growth/build/` for linux/darwin × amd64/arm64. No Go files exist at the repo root.

### Configuration Files

- **`healthcheck.conf`** (generated, or use `healthcheck.conf.example`) — Prometheus connection params (`_prom_server`, `_prom_port`, `_cs_version`, etc.), sourced by `runchk.sh`
- **`memcheck.conf`** — Expected RSS memory bounds (min/max MB) per service name
- **`hcpcs_hourly_alerts.json`** / **`hcpcs_daily_alerts.json`** — Prometheus alert query definitions with warning/error thresholds (50+ metrics)
- **`os.conf`** — OS-level configuration

## Coding Conventions

- All scripts use `#!/usr/bin/env bash` and source `gsc_core.sh` for logging/utilities
- Logging: use `gsc_log_info`, `gsc_log_warn`, `gsc_log_error`, `gsc_log_ok`, `gsc_die`
- Important info → console (stderr via `gsc_log_*`); details → log files via `gsc_loga`
- Summary sections delimited with `++++++++++` separator lines
- Scripts that need root check with `gsc_require_root`; dependency checks use `gsc_require <cmd>...`
- Version tracked in `VERSION` file (e.g., `v1.2.52`); update it and its git tag on each release
- CI (GitHub Actions) runs `bash -n` and `shellcheck` on every push/PR
- Do NOT include `Co-Authored-By:` lines in commit messages

## Summary Section Rules (runchk.sh)

The final summary aggregates lines from `health_report*.log` files via `grep -hE "ERROR|WARNING|CRITICAL|DANGER|ACTION|ALERT"`. Rules for what appears:

- `CRITICAL` / `ALERT` — highest severity, displayed first under `++++++++++ CRITICAL / ALERT ++++++++++`
- `DANGER` — between critical and error, displayed under `++++++++++ DANGER ++++++++++`
- `ERROR` — displayed under `++++++++++ ERROR ++++++++++`
- `WARNING` — displayed under `++++++++++ WARNING ++++++++++`
- `ACTION` — recommendations, displayed last under `++++++++++ ACTION ++++++++++`

The `_issues_filter` in `runchk.sh` excludes noise lines (partition count table rows, threshold legend lines). When adding new log output, ensure severity labels match these keywords so they surface correctly.

## Partition Analysis Rules

### `get_partition_details.sh` — partitionState bad partitions section

Severity and actions for each partition problem type:

| Type | Level | Action |
|------|-------|--------|
| `overprotection` | `[WARNING ]` | Monitor over a few days; if no decrease, contact ASPSUS for process to remove overprotected partitions |
| `underprotection` | `[DANGER  ]` | Contact ASPSUS — underprotected partitions are at risk of data loss |
| `unprotection` | `[CRITICAL]` | Contact ASPSUS — unprotected partitions require immediate action |
| `orphaned` | `[WARNING ]` | Contact ASPSUS for procedure to remove orphan partitions |
| `leaderless` | `[WARNING ]` | Research — leaderless partitions may cause availability issues |
| `No partitions found` | `[ OK     ]` | None |

Detail lines following a `Found N partitions...` line are redirected to `bad_partitions_analysis.log` (off-screen) until the next `No partitions found` line.

### Partition Growth Output Files

- `partition_growth_chart.log` — text-based growth rates from the `partition_growth` binary (`-a` flag); always generated when binary and JSON are present
- `partition_growth_plot.log` — ASCII plots from gnuplot when `gnuplot` is detected; contains tool requirements message when gnuplot is absent

When adding plot/chart output, always check for the required tool first. If missing, write a requirements message to the plot log file rather than silently skipping.

## Prometheus / chk_metrics.sh Rules

- `chk_metrics.sh` performs a connectivity pre-probe (`getOldestMetricTimestamp`) before the query loop
- If Prometheus is unreachable after both https and http attempts, it logs a single `ERROR: Prometheus ... is not reachable` and exits `0` (clean exit)
- This prevents flooding `health_report_metrics.log` with one `INTERNAL-ERROR: FAILED QUERY` line per metric (23+ lines)
- Empty curl reply (`REPLY:`) always means Prometheus is unreachable, not a query logic error

## Release Process

1. Update `VERSION` file to next version (e.g. `v1.2.58`)
2. Update `CHANGELOG.md` with entry and SHA256
3. Run `make bundle` — builds binaries, updates README version, creates `process_health_vX.Y.Z.tar.xz`
4. Commit changed files (`VERSION`, `CHANGELOG.md`, `README.md`, changed scripts)
5. Tag: `git tag vX.Y.Z && git push origin main && git push origin vX.Y.Z`
6. Create GitHub release: `gh release create vX.Y.Z process_health_vX.Y.Z.tar.xz --title "vX.Y.Z" --notes "..."`
