# Process Health Check

A health check and monitoring toolkit for **HCP Cloud Scale** (Hitachi Vantara) clusters. Processes support logs and Prometheus snapshots to surface errors, warnings, memory anomalies, and partition issues.

**Current version:** 1.1.64

---

## Requirements

| Dependency | Purpose |
|------------|---------|
| `bash` 3.2+ | Script runtime |
| `jq` | JSON processing (required) |
| `awk`, `grep`, `sed`, `find`, `tee` | Core utilities |
| `docker` or `podman` | Running Prometheus containers |
| `go` (optional) | Rebuilding the `partition_growth` binary |

Run `./selfcheck.sh` to validate all dependencies and required files before use.

---

## Quick Start

### Run all health checks

```bash
./runchk.sh [healthcheck.conf]
```

Runs `selfcheck.sh` first, then sequentially executes all checks and summarizes ERRORs and WARNINGs from output logs.

### Run Prometheus from a support snapshot (psnap)

```bash
sudo ./gsc_prometheus.sh \
  -c TEL \
  -s 05400896 \
  -f ./psnap_2026-Jan-05_13-36-41.tar.xz \
  -b ./prom \
  --replace
```

| Flag | Description |
|------|-------------|
| `-c` | Customer identifier |
| `-s` | Service request number |
| `-f` | Path to `.tar.xz` snapshot file |
| `-b` | Base directory for extraction |
| `--replace` | Remove and replace an existing container of the same name |
| `--engine auto\|docker\|podman` | Container engine (default: auto-detect) |
| `--image IMAGE` | Prometheus image (default: `docker.io/prom/prometheus:latest`) |
| `--keep-container` | Do not use `--rm`; leave container after exit |
| `--estimate` / `--estimate-only` | Preflight disk space check before extraction |

Prometheus port is auto-selected from the 9090–9200 range.

---

## Configuration

### `healthcheck.conf`
Optional config file for `runchk.sh`. Defines Prometheus connection parameters and output prefixes (e.g. `PROM_CMD_PARAM_DAILY`, `VERSION_NUM`).

### `memcheck.conf`
Defines expected RSS memory bounds (min/max MB) per service, consumed by `chk_services_memory.sh`:

```
Cassandra           2400 2600
Elasticsearch       8000 8200
Kafka               2000 2100
...
```

### `hcpcs_hourly_alerts.json` / `hcpcs_daily_alerts.json`
Prometheus metric definitions with query, warning threshold, and error threshold for 50+ events. Used by `chk_metrics.sh`.

---

## Key Scripts

| Script | Purpose |
|--------|---------|
| `runchk.sh` | Main orchestrator — runs all checks in sequence |
| `selfcheck.sh` | Validates dependencies and required files |
| `gsc_prometheus.sh` | Extracts psnap and runs Prometheus in a container |
| `chk_metrics.sh` | Queries Prometheus against alert definitions |
| `chk_services_memory.sh` | Validates service RSS memory against `memcheck.conf` bounds |
| `chk_collected_metrics.sh` | Validates quality of pre-collected metrics |
| `gsc_library.sh` | Shared logging library (sourced by all scripts) |
| `gsc_core.sh` | Core runtime: strict mode, container helpers, safe tar, dependency checks |

Service-specific scripts for HCP software versions 25 and 26 are in `services_sh_25/` and `services_sh_26/`.

---

## Partition Growth Analysis

A Go tool for analyzing partition growth trends from JSON event data:

```bash
./partition_growth/build/partition_growth-$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m) \
  -f data.json \
  -y 2025 \
  -m 1
```

Pre-compiled binaries for darwin/linux × amd64/arm64 are in `partition_growth/build/`. To rebuild:

```bash
cd partition_growth && make all
```

---

## Development

```bash
make bash-n     # Syntax check all .sh files (bash -n)
make lint       # Run shellcheck on all .sh files
make bundle     # Create a release tar.xz archive
```

CI runs `bash -n` and `shellcheck` on every push and pull request via GitHub Actions.
