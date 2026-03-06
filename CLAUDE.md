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

To rebuild Go binaries:
```bash
cd partition_growth   && make all
cd cluster_forecast   && make all
cd parse_instances    && make all
cd chk_snodes         && make all
cd chk_alerts         && make all
cd hcpcs_alertengine  && make all
cd hcpcs_db           && make all
```

## Architecture

### Entry Points

| Script | Role |
|--------|------|
| `gsc_healthcheck.sh` | End-to-end orchestrator: expands support bundle(s) → starts Prometheus per psnap → runs `runchk.sh`. Handles multiple support log directories via `_run_dir_checks()`. |
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

### Test Scripts (dev-only, excluded from release bundle)

| Script | Role |
|--------|------|
| `test_healthcheck.sh` | End-to-end test: rsync deploy → run `gsc_healthcheck.sh` against each `/ci/<SR>` directory |
| `test_battery.sh` | Full sequence battery test: deploy → global prometheus cleanup → expand bundle → prometheus → runchk (twice: plain + `--report`) |

Both scripts:
- Accept optional SR filter args: `sudo bash test_battery.sh 05448336 05455380`
- Set `TMPDIR=/var/ci/tmp` and pass it through `sudo`
- Clean stale `2025*/2026*` run dirs before each SR
- Cycle customer names: `HV ACME THOR ODEN LOKI`
- Write main log to `/ci/test_<name>_YYYYMMDD_HHMMSS.log` and per-SR log to `/ci/<SR>/run_battery_*.log`

### Go Components

All Go binaries follow the same pattern: `<name>/main.go` + `<name>/Makefile`, cross-compiled for linux/darwin × amd64/arm64 into `<name>/build/`. Shell scripts detect OS/arch via `uname -s -m`, dispatch to the binary, and fall back to jq on failure.

| Binary | Directory | Replaces | Shell script caller |
|--------|-----------|----------|---------------------|
| `partition_growth` | `partition_growth/` | — (original Go) | `runchk.sh` (direct call) |
| `cluster_forecast` | `cluster_forecast/` | — (new) | `gsc_healthcheck_report.sh` (`--forecast`) |
| `parse_instances` | `parse_instances/` | N×M jq subprocess loop | `parse_instances_info.sh` |
| `chk_snodes` | `chk_snodes/` | grep-on-JSON counting | `chk_snodes.sh` |
| `chk_alerts` | `chk_alerts/` | `.events[].time` bug + jq | `chk_alerts.sh` |
| `hcpcs_alertengine` | `hcpcs_alertengine/` | Sequential curl+jq (50+ queries) | `chk_metrics.sh` |
| `hcpcs_db` | `hcpcs_db/` | — (new: results DB) | `runchk.sh` (when `HCPCS_DB` set) |
| `chk_partition_sizes` | `chk_partition_sizes/` | — (new) | `chk_partition_sizes.sh` |

**`partition_growth/main.go`** — Analyzes partition growth trends from JSON event data. `-a` flag outputs chart + `avg_monthly_growth: N splits/month` line.

**`cluster_forecast/main.go`** — Reads `health_report_partition_details.log`, `health_report_services*.log`, and `partition_splits.log` to produce a 12-month MDGW node sizing forecast. CLI: `--dir`, `--threshold-current`, `--threshold-new`, `--mdgw`. Handles `MDGW instances: N/A` by defaulting to 1 (with warning) or `--mdgw N` override.

**`parse_instances/main.go`** — Parses instances JSON (`foundry_instances.json` / `config_foundry_instances.out`) into the per-node and per-service summary written to `hcpcs_services_info.log`. Preserves insertion-order service registry. Fixes N×M `jq` subprocess overhead for large clusters.

**`chk_snodes/main.go`** — Validates storage component config JSON. Checks `storageType==HCPS_S3`, `https==true`, `port==443`, `maxConnections==1024`. Fixes grep-on-JSON false negatives in the original bash (e.g. `grep "https" | grep -c "true"` matched any field).

**`chk_alerts/main.go`** — Reads alert-list JSON and system-info events JSON; filters to last N days; deduplicates events by subject. CLI: `--dir` (WalkDir with `strings.Contains` for numeric-prefixed filenames), `--alerts`, `--events`, `--output`, `--days`. Fixes two original bash bugs: uses `.timestamp` (not `.time`) for event filtering, and deduplicates by full subject string (not first word).

**Dispatch placement rule for chk_alerts.sh:** Binary dispatch runs **before** the `find | grep -m 1 | head -n 1` file-discovery pipelines. Those pipelines produce SIGPIPE exit 141 under `set -euo pipefail` (from `gsc_core.sh`), killing the script before reaching a later dispatch block. The binary does its own discovery via `--dir`.

**`hcpcs_alertengine/main.go`** — Replaces the sequential curl+jq query loop in `chk_metrics.sh`. Issues all Prometheus range/instant queries in parallel (goroutines). Handles: protocol auto-switch (https→http), unreachable Prometheus (clean exit 0, single ERROR line), per-alert `Step` override, `ConsecutiveProbes` logic, label fan-out, `Exclude` filter, `Ignore` criteria, TELEMETRY mode (min/max/avg over all probes), `%PROBESTEP`/`%THRESHOLD` substitution. Output format mirrors `chk_metrics.sh` exactly (matches summary `grep -hE "ERROR|WARNING"`). CLI: `--host`, `--port`, `--proto`, `--json`, `--output`, `--probes`, `--interval`, `--date`, `--threshold`, `--no-range`.

**`chk_partition_sizes/main.go`** — Reads `clusterPartitionState_Metadata-Coordination_*.json` files (object keyed by partition string ID; values have `partitionId`, `partitionSize` bytes, `keySpaceId`, `nodes[]`). Deduplicates by `partitionId` across multiple files. Sorts by `partitionSize` descending. Writes flat tab-separated `partition_size_analysis.log`. Emits `[WARNING] <threshold> Partitions are larger than expected … MDCO may need investigation.` when largest >= 1.5× split threshold. Threshold string parsed with unit conversion (Gi/G/Mi/M/Ki/K → bytes; all treated as binary). Integer-only 1.5× check: `2×max >= 3×thresh`. CLI: `--dir`, `--threshold`, `--output`. Shell caller: `chk_partition_sizes.sh` (reads threshold from `health_report_partitionInfo.log`; falls back to jq). Called from `runchk.sh` after `chk_partInfo.sh`.

**`hcpcs_db/main.go`** — SQLite-backed results database (pure Go via `modernc.org/sqlite`, CGO-free). Stores per-run severity counts and all filtered issues. Auto-invoked by `runchk.sh` when `HCPCS_DB` env var is set.

Schema: `runs` (id, ts, run_dir, sr_number, customer, cs_version, node_count, elapsed_sec, *_count, issues_total) + `issues` (run_id, severity, source, message).

Commands:
- `record [--elapsed N] [--customer NAME] [--sr SR] [--dir DIR]` — Scan `health_report*.log` in cwd (or `--dir`), apply `_issues_filter` noise patterns, insert run + issues in one transaction.
- `list [--limit N] [--sr SR]` — Aligned table: ID, Timestamp, SR, Customer, Version, Nodes, Elapsed, CRIT/DANG/ERR/WARN/ACT.
- `show <id>` — Group issues by severity with `── SEVERITY ──` headers.
- `trend <sr>` — Per-run row for one SR with ↑/↓/→ trend arrows vs previous run.
- `serve [--db PATH]` — MCP stdio server (JSON-RPC 2.0). Exposes `list_runs`, `show_run`, `trend_sr`, `record_run` as MCP tools callable by Claude or any MCP-compatible agent.

Integration:
- `runchk.sh`: after `_elapsed` is computed, if `HCPCS_DB` is set → dispatch binary with `record --elapsed ${_elapsed}` (+ `--customer` from `HCPCS_CUSTOMER` env var).
- `gsc_healthcheck.sh`: passes `HCPCS_CUSTOMER="${_customer}"` when calling `runchk.sh`.
- `~/.claude/settings.json`: registers `hcpcs_db serve` as an MCP server so Claude can call DB tools natively.
- `~/.claude/skills/hcpcs-db.md`: `/hcpcs-db` skill for manual invocation (list/show/trend/record).

Default DB path: `~/.local/share/hcpcs/results.db` (overridden by `HCPCS_DB` env var).

**MCP serve implementation:** JSON-RPC 2.0 over stdin/stdout. Responds to `initialize` (returns `protocolVersion: 2024-11-05`), `tools/list` (returns 4 tool defs with JSON Schema), and `tools/call`. Notifications (no `id` field) are silently ignored. Print helpers (`printList`, `printShow`, `printTrend`) accept `io.Writer` so they serve both CLI (stdout) and MCP (strings.Builder → content text) paths.

### Long-term Go Conversion Plan

**Phase 3 — `chk_collected_metrics`:** Convert `chk_collected_metrics.sh` to Go. Reads pre-collected Prometheus JSON (different schema: AlertID/TelemetryID format from `hcpcs_alerts_def.json`), processes against alert definitions, writes `.log` + `.json` + `_pretty.json` output. Lower priority since it requires a separate collection binary to produce the input JSON.

### Configuration Files

- **`healthcheck.conf`** (generated, or use `healthcheck.conf.example`) — Prometheus connection params (`_prom_server`, `_prom_port`, `_cs_version`, etc.), sourced by `runchk.sh`
- **`memcheck.conf`** — Expected RSS memory bounds (min/max MB) per service name
- **`hcpcs_hourly_alerts.json`** / **`hcpcs_daily_alerts.json`** — Prometheus alert query definitions with warning/error thresholds (50+ metrics)
- **`os.conf`** — OS-level configuration
- **`docker_version.conf`** — Minimum Docker version (`_minimum_version=20.10.5`). Sourced by `chk_docker.sh`; `_ver_gte()` helper compares each node's Docker version (major.minor.patch). WARNING if below minimum.
- **`cs_version.conf`** — Minimum HCP-CS version (`_cs_version=2.1.65`). Sourced by `chk_cluster.sh`; `_ver_gte()` helper compares detected product version (up to 4 parts: major.minor.patch.build). WARNING if below minimum.

## Coding Conventions

- All scripts use `#!/usr/bin/env bash` and source `gsc_core.sh` for logging/utilities
- Logging: use `gsc_log_info`, `gsc_log_warn`, `gsc_log_error`, `gsc_log_ok`, `gsc_die`
- Important info → console (stderr via `gsc_log_*`); details → log files via `gsc_loga`
- Summary sections delimited with `++++++++++` separator lines
- Scripts that need root check with `gsc_require_root`; dependency checks use `gsc_require <cmd>...`
- Version tracked in `VERSION` file (e.g., `v1.2.62`); update it and its git tag on each release
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

- `partition_growth_chart.log` — text-based growth rates from the `partition_growth` binary (`-a` flag); always generated when binary and `partitionSplit.json` are present; includes `avg_monthly_growth: N splits/month`
- `partition_splits.log` — copy of `partition_growth_chart.log` created by `runchk.sh` immediately after the binary runs; used by `gsc_healthcheck_report.sh` as the source for `--chart` section extraction
- `partition_growth_plot.log` — ASCII plots from gnuplot when `gnuplot` is detected; contains tool requirements message when gnuplot is absent

**Sequencing rule:** `partition_growth` binary must run **before** `get_partition_details.sh` in `runchk.sh` so that `avg_monthly_growth` is available for the Cluster Expansion Sizing section. The binary no longer requires `_max_partitions > 1500`; it runs whenever `partitionSplit.json` exists.

When adding plot/chart output, always check for the required tool first. If missing, write a requirements message to the plot log file rather than silently skipping.

### avg_monthly_growth Calculation (`partition_growth/main.go`)

The `-a` flag outputs a `--- 6-Month Average Monthly Growth ---` section:
- Takes the most recent 6 calendar months with data
- Detects trend by comparing first-half vs second-half per-month averages (cross-multiplied to avoid float division)
- **Increasing or flat** → round **up** (ceiling integer division)
- **Decreasing** → round **down** (floor integer division)
- Final line: `avg_monthly_growth: N splits/month` — parsed by `get_partition_details.sh`

## Prometheus / chk_metrics.sh Rules

- `chk_metrics.sh` performs a connectivity pre-probe (`getOldestMetricTimestamp`) before the query loop
- If Prometheus is unreachable after both https and http attempts, it logs a single `ERROR: Prometheus ... is not reachable` and exits `0` (clean exit)
- This prevents flooding `health_report_metrics.log` with one `INTERNAL-ERROR: FAILED QUERY` line per metric (23+ lines)
- Empty curl reply (`REPLY:`) always means Prometheus is unreachable, not a query logic error

### runchk.sh Prometheus skip logic

`runchk.sh` emits `[WARN] # SKIP chk_metrics.sh: Prometheus host not found in healthcheck.conf` in **all three** no-metrics cases:
1. `--no-metrics` flag passed (e.g. no psnap, no conf — set by `gsc_healthcheck.sh`)
2. `healthcheck.conf` exists but `_prom_server` is not configured
3. `_prom_server` is configured but Prometheus is not reachable (5-second `curl /-/ready` probe, tries both configured protocol and http fallback)

**Never** run `chk_metrics.sh` without a successful reachability probe first.

## Release Process

1. Update `VERSION` file to next version (e.g. `v1.2.63`)
2. Update `CHANGELOG.md` with entry and SHA256
3. Run `make bundle` — builds Go binaries, updates README version, creates `process_health_vX.Y.Z.tar.xz`
   - Bundle **excludes**: `test_*.sh`, `test_*.go`, `mock_curl.sh`, `CLAUDE.md`, `.git/`, `*.tar.xz`, `*.sha256`, `*.log`
4. Commit changed files (`VERSION`, `CHANGELOG.md`, `README.md`, changed scripts, rebuilt binaries)
5. Tag: `git tag vX.Y.Z && git push origin main && git push origin vX.Y.Z`
6. Create GitHub release: `gh release create vX.Y.Z process_health_vX.Y.Z.tar.xz --title "vX.Y.Z" --notes "..."`
7. After release, merge `main` → `dev`: `git checkout dev && git merge main && git push`

## Temp Directory / mktemp Rules

- Always use `mktemp -d` (not `mktemp`) when creating temp dirs in scripts, then register the **subdirectory** with `gsc_add_tmp_dir`
- **Never** register `$(dirname "$(mktemp)")` — that registers the parent `TMPDIR` itself, which `gsc_cleanup` will delete and break subsequent runs
- CI sets `TMPDIR=/var/ci/tmp` and passes it through `sudo` via `sudo TMPDIR=... cmd`
- `gsc_healthcheck.sh` uses `_tmp_dir=$(mktemp -d); gsc_add_tmp_dir "${_tmp_dir}"` — cleanup removes only the subdir

## gsc_healthcheck_report.sh Rules

- `_count_severity()` uses `grep -c` which always outputs a count (including `0`) and exits 1 on no match
- **Never** add `|| echo 0` after `grep -c` — it produces `0\n0` causing arithmetic errors; use `|| true` instead
- HTML-escape text **before** adding colour spans in `_colorize_pre()` to prevent entity re-escaping
- Option parsing uses `while/case` (not `getopts`) to support long options such as `--chart`
- `--chart <sections>` — comma-separated list of partition growth sections to include in the report: `yearly`, `quarterly`, `monthly`. When absent, no Growth Trends section is rendered. Sections always appear in file order (yearly → quarterly → monthly) regardless of list order. Source file is `partition_splits.log` (not `partition_growth_chart.log`).
- `_extract_chart_section()` — awk helper that extracts one named `--- Header ---` section from `partition_splits.log`, stopping at the next `--- ` line
- `--forecast N` — calls `cluster_forecast` binary with `--dir . --threshold-new N`; embeds output after `### Density Details` in both Markdown and HTML/PDF reports. N is the proposed partition size threshold in GB. When absent, no forecast section is rendered. Platform detection (`uname -s -m`) selects the correct pre-compiled binary from `cluster_forecast/build/`.
- `_run_forecast()` — helper that detects OS/arch, locates binary, and calls it; returns empty string (skips silently) if binary or `partition_splits.log` is absent

## gsc_healthcheck.sh Multi-Support-Log Rules

When `expand_hcpcs_support.sh` extracts more than one support log, multiple `YYYY-MM-DD_HH-MM-SS` directories are created. `gsc_healthcheck.sh` handles this as follows:

- After expansion, **all** timestamp dirs under the SR base directory are collected (not just the most recent)
- **1 support log** → customer name used as-is; single dir processed as normal
- **2+ support logs** → each dir gets a unique random 4-digit suffix: `ACME_2341`, `ACME_8076`, etc.
- The suffix is applied to the customer name passed to `gsc_prometheus.sh` via `-c`, making container names (`gsc_prometheus_ACME_2341_SR_PORT`) globally unique and preventing collisions
- Each directory is processed in its own subshell via `_run_dir_checks <customer>` so that state (e.g. `_no_metrics`) does not leak between runs
- Within a single directory, if multiple psnaps exist, the existing per-psnap suffix logic still applies on top: `ACME_2341_5060`, `ACME_2341_3917`
- Data directories created by `gsc_prometheus.sh` (`<base>/<customer>/<SR>/prom/data`) are also unique as a side effect of the unique customer name
