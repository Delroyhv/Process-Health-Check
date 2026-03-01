# Process Health Check

A health check and monitoring toolkit for **HCP Cloud Scale** (Hitachi Vantara) clusters. Processes support logs and Prometheus snapshots to surface errors, warnings, memory anomalies, and partition issues.

**Current version:** v1.1.67

---

## Requirements

| Dependency | Purpose |
|------------|---------|
| `bash` 3.2+ | Script runtime |
| `jq` | JSON processing (required) |
| `awk`, `grep`, `sed`, `find`, `tee` | Core utilities |
| `docker` or `podman` | Running Prometheus containers |
| `go` (optional) | Rebuilding the `partition_growth` binary |
| `gnuplot-nox` | Generating ASCII line graphs |

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
  -c CUSTOMER \
  -s 01234567 \
  -f ./psnap_2026-Jul-04_12-53-12.tar.xz \
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

### Run Grafana with HCP dashboards

```bash
sudo ./gsc_grafana.sh \
  --docker \
  -D ./DashBoards/GrafanaDashboards_2.6.zip \
  --prometheus-data-source 172.22.20.26:9090
```

| Flag | Description |
|------|-------------|
| `-d`, `--docker` | Use Docker as the container engine |
| `-p`, `--podman` | Use Podman as the container engine |
| `-D`, `--dashboard FILE` | Path to dashboard JSON or `.zip` archive |
| `--url URL` | Download dashboards from a URL |
| `--git URL` | Clone a Git repository containing dashboards |
| `-i`, `--prometheus-data-source IP:PORT` | Specify the Prometheus datasource address |
| `-g`, `--grafana-port PORT` | Specify the Grafana port (default: 3000) |
| `--update` | Update configuration without clearing existing dashboards |
| `--query` | Interactive scan for Prometheus sources to set datasource |

Grafana is accessible at `http://localhost:3000` (or your custom port) (admin/admin). Provisioned data sources are set to `editable: true`.

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
| `gsc_grafana.sh` | Sets up Grafana with provisioned HCP dashboards and datasources |
| `chk_metrics.sh` | Queries Prometheus against alert definitions |
| `chk_services_memory.sh` | Validates service RSS memory against `memcheck.conf` bounds |
| `chk_collected_metrics.sh` | Validates quality of pre-collected metrics |
| `gsc_library.sh` | Shared logging library (sourced by all scripts) |
| `gsc_core.sh` | Core runtime: strict mode, container helpers, safe tar, dependency checks |

Service-specific scripts for HCP software versions 25 and 26 are in `services_sh_25/` and `services_sh_26/`.

---

## Partition Growth Analysis

A Go tool for analyzing partition growth trends from JSON event data. It can summarize growth by year, quarter, or week.

### Usage

```bash
./partition_growth/build/partition_growth-$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m) \
  -f data.json \
  -y 2025 \
  -m 1
```

### Visualizing Trends (Line Graphs)

Using `gnuplot`, you can generate ASCII line graphs for clearer trend visualization:

```bash
# Example year-to-year trend
gnuplot partition_growth/plot.gp
```

**Sample Output:**
```text
                             Year-to-Year Partition Growth                      
     1100 +-----------------------------------------------------------------+   
          |          +          +          +        **A          +          |   
     1000 |-+                                   ****   **Partitions ***A***-|   
      900 |-+                              *****         *                +-|   
          |                            ****               *                 |   
      800 |-+                      ****                    **             +-|   
          |                    *A**                          *              |   
      700 |-+                **                               *           +-|   
      600 |-+              **                                  **         +-|   
          |              **                                      *          |   
      500 |-+          **                                         **      +-|   
      400 |-+        **                                             *     +-|   
          |        **                                                *      |   
      300 |-+    **                                                   **  +-|   
          |    **                                                       *   |   
      200 |-+**                                                          *+-|   
      100 |**                                                             **|   
          |          +          +          +          +          +          |   
        0 +-----------------------------------------------------------------+   
         2023      2023.5      2024      2024.5      2025      2025.5      2026 
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
