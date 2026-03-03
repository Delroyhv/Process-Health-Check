# Process Health Check

A health check and monitoring toolkit for **HCP Cloud Scale** (Hitachi Vantara) clusters. Processes support logs and Prometheus snapshots to surface errors, warnings, memory anomalies, and partition issues.

**Current version:** v1.2.43

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
| `sudo` | Required for `gsc_prometheus.sh` and cleanup operations |

Run `./selfcheck.sh` to validate all dependencies and required files before use.

---

## Quick Start

### End-to-End Health Check with `gsc_healthcheck.sh`

The `gsc_healthcheck.sh` script orchestrates the entire health check workflow. It handles support bundle expansion, Prometheus setup, and running the `runchk.sh` suite.

```bash
sudo ./gsc_healthcheck.sh -c CUSTOMER_NAME -s SR_NUMBER -f /path/to/supportLogs_BUNDLE.tar.xz
```

### Order of Operations (`gsc_healthcheck.sh`)

When `gsc_healthcheck.sh` is invoked, it performs the following sequence of operations:

1.  **Expand Support Bundle (`expand_hcpcs_support.sh`)**:
    *   If a support log file (`-f`) is provided (e.g., `supportLogs_BUNDLE.tar.xz`), `gsc_healthcheck.sh` first calls `expand_hcpcs_support.sh -f /path/to/supportLogs_BUNDLE.tar.xz` (or similar arguments depending on the bundle type).
    *   `expand_hcpcs_support.sh` extracts the contents of the bundle into a timestamped directory (e.g., `YYYY-MM-DD_HH-MM-SS`) typically located under `.` or `/ci/<SR_NUMBER>/`.
    *   **Example Call:** `expand_hcpcs_support.sh -f supportLogs_2026-01-01.tar.xz`
    *   **Output:** Creates a directory like `./2026-01-01_12-34-56/` containing extracted data and a `healthcheck.conf` file.

2.  **Locate and Change Directory**:
    *   The script then identifies the newly created (or existing) timestamped health check directory.
    *   It changes the current working directory to this `healthcheck_dir`. All subsequent commands (`gsc_prometheus.sh`, `runchk.sh`) are executed from within this directory, ensuring they operate on the correct data.
    *   **Example `cd`:** `cd ./2026-01-01_12-34-56/`

3.  **Run Prometheus Setup (`gsc_prometheus.sh`)**:
    *   If a Prometheus snapshot (`psnap_*.tar.xz`) is found within the `healthcheck_dir` and the `--no-psnap` or `--no-metrics` flags are not used, `gsc_healthcheck.sh` will initiate the Prometheus setup.
    *   It invokes `gsc_prometheus.sh` with `sudo`, passing the customer name, SR number, the detected snapshot file, and instructing it to use the current directory (`.`) as its base.
    *   **Note:** `gsc_prometheus.sh` now defaults to *not* using file locking. Use the `--concurrent` option if running multiple instances simultaneously to enable `flock` with a 120-second timeout.
    *   **Example Call:** `sudo gsc_prometheus.sh -c CUSTOMER_NAME -s SR_NUMBER -f psnap_FILE.tar.xz -b .`
    *   **Result:** A Prometheus container is started, and `healthcheck.conf` is updated with the Prometheus port.

4.  **Execute Health Check Suite (`runchk.sh`)**:
    *   Finally, `gsc_healthcheck.sh` executes `runchk.sh`.
    *   It passes the generated (or existing) `healthcheck.conf` file using the `-f` flag. If metrics were disabled (via `--no-psnap` or `--no-metrics`), `runchk.sh` also receives `--no-metrics`.
    *   **Example Call:** `runchk.sh -f healthcheck.conf [--no-metrics]`
    *   **Result:** The full suite of health checks is performed, and a summary is printed to the console. If high partition counts are detected, a "Quarterly Partition Growth" chart is displayed to the screen, while other detailed charts are logged to `partition_growth_chart.log`.

### Sudo Password Management

`gsc_healthcheck.sh` transparently handles `sudo` password prompting. If `sudo` access requires a password, you will be prompted once at the beginning of the script execution. The password is then securely stored using `gsc_vault` (AES-encrypted) and used for all subsequent `sudo` operations without re-prompting. This vaulted password is automatically wiped from memory when `gsc_healthcheck.sh` completes.

---

### Run `runchk.sh`
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
| `--engine auto\|docker\|podman` | Container engine (default: auto) |
| `--image IMAGE` | Prometheus image (default: `docker.io/prom/prometheus:latest`) |
| `--keep-container` | Do not use `--rm`; leave container after exit |
| `--min-port N` | Minimum port (default: `9090`) |
| `--max-port N` | Maximum port (default: `9599`) |
| `--exclude-port N` | Additional port(s) to exclude (repeatable) |
| `--concurrent` | Enable file locking for concurrent port selection (120s timeout) |
| `--debug` | Enable verbose logging |
| `-e`, `--estimate` | Enable pre-extract space check |
| `--estimate-only` | Only run estimate (no extract / container) |
| `--cleanup` | Stop and remove managed Prometheus containers |
| `--volume` | Delete data directories during cleanup (requires `--cleanup`) |
| `--override=y` | Skip confirmation prompts for cleanup |
| `--no-space-check` | Disable free-space safety check |
| `--no-color` | Disable ANSI color output |
| `--version` | Show version |
| `-h`, `--help` | Show help |

Notes:
  - Ports are selected automatically and skip:
      * reserved exporter ports: 9093, 9100, 8080, 9115, 9116, 9104
      * ports mapped by running containers
      * extra excluded ports from config/CLI

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
| `--admin-password PASSWORD` | Specify the Grafana admin password (default: admin) |
| `--update` | Update configuration without clearing existing dashboards |
| `--query` | Interactive scan for Prometheus sources to set datasource |
| `--cleanup` | Stop and remove the Grafana container |
| `--volume` | Delete dashboards and provisioning directories during cleanup (requires `--cleanup`) |
| `--override=y` | Skip confirmation prompts for cleanup |

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
| `gsc_healthcheck.sh` | End-to-end orchestrator for health checks, handling expansion, Prometheus setup, and `runchk.sh` execution. |
| `runchk.sh` | Main health check suite orchestrator — runs all checks in sequence |
| `selfcheck.sh` | Validates dependencies and required files |
| `gsc_prometheus.sh` | Extracts psnap and runs Prometheus in a container |
| `gsc_grafana.sh` | Sets up Grafana with provisioned HCP dashboards and datasources |
| `chk_metrics.sh` | Queries Prometheus against alert definitions |
| `chk_services_memory.sh` | Validates service RSS memory against `memcheck.conf` bounds |
| `chk_collected_metrics.sh` | Validates quality of pre-collected metrics |
| `gsc_library.sh` | Shared logging library (sourced by all scripts) |
| `gsc_core.sh` | Core runtime: strict mode, container helpers, safe tar, dependency checks, secure sudo management |
| `gsc_vault.go` | Go utility for AES-encrypted credential storage used by secure sudo management |

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
All code is modular.
Each function should have inline documentation.
Display to the user should give important information.
Details should be kept to the logs.
Consistent in summary part: break each level with ++++++++++
All common functions must be centralized in gsc_core.sh to ensure consistency and modularity.
As a senior software developer, always perform a thorough security review before any commit to ensure no secrets, credentials, or sensitive paths are exposed.
After modifications, update and push code locally.
Update VERSION file and it should also contain a tag.
Working directory: /home/dablake/src/Process-Health-Check

New Dependencies:
- gnuplot-nox: Used for generating ASCII line graphs for partition growth analysis.
- go: Used to build the high-performance `gsc_calc` arithmetic utility.

Current Status:
- CLI updated to 0.31.0.
- Partition growth analysis completed for case 01234567.
- VERSION updated to v1.2.14.
- Centralized all common functions into `gsc_core.sh`.
- Implemented and optimized arithmetic logic using a new Go-based utility `gsc_calc`.
- Added robust cleanup functions to `gsc_prometheus.sh` and `gsc_grafana.sh`.
- Integrated secure `sudo` password management.
--- End of Context from: GEMINI.md ---
