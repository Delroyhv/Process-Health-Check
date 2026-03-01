## v1.2.00
- **Major Update:** Integrated Go-based secure vault (`gsc_vault`) for AES-GCM credential encryption.
- **Performance:** Optimized arithmetic and comparison logic using compiled Go utility (`gsc_calc`), replacing slow `bc` calls.
- **Maintenance:** Centralized all common functions into `gsc_core.sh`.
- **Resource Management:** Added robust `--cleanup` functionality to `gsc_prometheus.sh` and `gsc_grafana.sh` to release ports and containers.
- **Compliance:** Established mandatory senior developer security review process for all commits.

### SHA256
```
bbd89446a8ec1080e8ecf0cd0b8673f0584384782f2fd527b18142f2b0b22c2a  process_health_v1.2.00.tar.xz
```

## v1.1.67
- Integrated partition growth analysis with gnuplot visualization.
- Standardized all documentation examples with numeric dummy IDs (01234567).
- Updated versioning methodology to use the 'v' prefix in filenames.
- Scrubbed all AI tool references from the repository.

### SHA256
```
2a7198d07b45a91326b8ba669ae80b3c89b0e64f363c7d50ab34dbce9e3ceddb  process_health_v1.1.67.tar.xz
```

## v1.1.65
- Fix gsc_grafana.sh: support both Docker Compose V2 plugin (`docker compose`) and V1 standalone (`docker-compose`) via a local array `_compose_cmd`; clear error if neither is found.
- Fix gsc_grafana.sh: auto-detect container engine via `gsc_detect_engine()` when neither `--docker` nor `--podman` is passed; `--docker`/`--podman` flags are now optional.
- Fix gsc_grafana.sh: write `docker-compose.yaml` only when engine is docker; podman path no longer leaves a stray compose file on disk.
- Fix gsc_grafana.sh: add preflight `gsc_require` checks for the selected container engine, `curl`/`wget` (when `--url` is used), and `git` (when `--git` is used); engine detection moved before download/clone so all checks run before any work begins.
- Fix gsc_grafana.sh: replace hardcoded `sleep 5` + one-shot container check with `_wait_for_container()` polling helper (5 s interval, 60 s max); returns immediately on success and logs progress on each retry.
- Remove gsc_grafanav3.sh: buggy duplicate of gsc_grafana.sh (literal-string URL guard, missing gsc_core.sh, unscoped variable in clone_git_repo).
- Add Grafana dashboards archive (`DashBoards/GrafanaDashboards_2.6.zip`) for HCP CS 2.6.
- Makefile: add `make readme` target that stamps the VERSION file value into the `**Current version:**` line of README.md; wire as a dependency of `make bundle` so README.md is always in sync with the release version.
- Mark all `.sh` files executable (mode 100755).

### SHA256
```
3d8d7c5f8afa6139fdb9f0509cc0518ce5f97a6e0145736d03b79824163088c9  process_health_1.1.65.tar.xz
```

## v1.1.63
- Fix runchk.sh: uncomment partition info gathering scripts (`get_partition_info.sh`, `get_partition_tool_info.sh`, `chk_partInfo.sh`) and remove duplicates.
- Repository Cleanup: Removed obsolete `./release/` directory containing broken code and cleared dozens of old `.tar.xz` bundles from the root.
- Build Improvement: `make bash-n` now passes correctly across the entire toolkit.

### SHA256
```
547753c5c1a8a18f2a0e20c3912de8a25f1cdf3341f4b57f5ddb1d8d9ccbd52c  process_health_v1.1.63.tar.xz
```

## v1.1.62
- Cleaned up repository by removing old scan reports and Mac OS X resource forks.

### SHA256
```
b28e26a69b97f002fb30d125cebbf26dc46198d33c06b84b43d48648e3fc9315  process_health_v1.1.62.tar.xz
```

## v1.1.61
- Added `healthcheck.conf.example` template for easier configuration setup.
- Enhanced partition details with a color-coded threshold legend.
- Implemented service placement check for master nodes in partition details.
- Included EXTENDED partition information in details search for deeper analysis.
- Fixed memory summary logic and refined reporting filters for better accuracy.

### SHA256
```
99f4122fd1ce651876eda9d2280d11195164adcf8ba9cc05435643473dfa84d6  process_health_v1.1.61.tar.xz
```

## v1.1.60
- Implement "Latest Per Node" deduplication logic in print_node_memory_summary.sh (lsmem/free) to ensure reporting reflects the 7-node cluster state.
- Consolidated final summary in runchk.sh:
    - Sort issues by severity: CRITICAL/ALERT > ERROR > WARNING > ACTION.
    - Improved visual style for CRITICAL: high-intensity bright red background with bold white text (\033[1;101;97m).
    - New ACTION log level with precise blue color (#2563EB).
    - Prefixes (health_report_*.log:) stripped from terminal output for better readability.
- Enhanced get_partition_details.sh:
    - Added cluster expansion sizing logic: (total partitions * 3) / 900 + 1 growth node.
    - Integrated monthly growth projection from splitpartition history.
    - Leadership imbalance detection (>10%) with MDCO troubleshooting note.
- chk_services_memory.sh:
    - Add 512GB node memory profile detection.
    - Implement baseline tested configuration check (256GB - 30GB OS = 226GB limit).
    - Automated JIRA recommendation for high-memory configurations exceeding baseline.
- chk_chrony.sh: group and consolidate NTP source warnings by specific reachable/total patterns (e.g., '1 of 1', '2 of 2').
- chk_partInfo.sh: intelligently skip partition state analysis if input log has < 15 lines (incomplete sample).
- Rearrange runchk.sh execution order: chk_cluster executes after node OS summary; get_partition_details captured to log for summary.

### SHA256
```
d29a43d1f872f8cea152a35e00ec2f104df4f1dbe79b656a192df652116a14ee  process_health_v1.1.60.tar.xz
```

## v1.1.59
- Implement "Latest Per Node" deduplication logic in chk_chrony.sh, chk_top.sh, and chk_lshw.sh to ensure reporting reflects the 7-node cluster state by ignoring historical data files.
- Consolidate Chrony reporting: group unreachable, degraded, and insufficient sources into node-count summaries.
- Consolidate service run config reporting: group modified .sh files by service type with per-node details moved to logs.
- Integrated chk_buckets.sh into runchk.sh with automatic terminal output.
- chk_partInfo.sh: replace gawk-specific asorti with mawk-compatible manual sort for partition split growth.
- chk_top.sh: replace gawk-specific match() captures with portable index/substr logic; add non-empty check for metrics.
- chk_service_placement.sh: consolidate error reports — group master nodes by flagged service type for cleaner output.
- runchk.sh: correct variable name mapping (VERSION_NUM, PROM_CMD_PARAM_DAILY) to match healthcheck.conf.
- Add get_partition_details.sh: granular partition map/state analysis with tiered thresholds, leadership imbalance detection (>10%), and ASPSUS JIRA recommendation for high partition counts at 1Gi thresholds.
- Add generate_partition_report.sh: high-level summary of partition balance and safety.

### SHA256
```
207cd0ea4aed3b6e4369c6d2bf1ab3f6cd6d295524ecafe07e6c38b7bfc2c404  process_health_v1.1.59.tar.xz
```

## v1.1.58
- runchk.sh: fix healthcheck.conf sourcing — prepend `./` to bare filename so bash 5.2's `.` command resolves the file from CWD instead of PATH; without this, the install-dir template (`/usr/local/bin/healthcheck.conf`) was sourced instead of the customer conf, causing chk_metrics.sh to run against the wrong Prometheus port.

### SHA256
```
bedb16080f7edffae7904b1cd79278cdcddd76010d95f76eac45c9ffdd466327  process_health_v1.1.58.tar.xz
```

## v1.1.57
- Add docs/: Markdown and PDF renderings of all four man pages generated via pandoc (man→gfm) and groff+ps2pdf (man→ps→pdf); add Makefile target `make docs` to regenerate from source man pages (requires pandoc, groff, ghostscript/ps2pdf).

### SHA256
```
bf0c523c539128193d938cfad98bde80b5886707fd26934cb2ba0c4d2a4ce644  process_health_v1.1.57.tar.xz
```

## v1.1.56
- runchk.sh: modular option parsing — replace positional-only config arg with -f <file>; add --full-detail flag (enables chk_disk_perf.sh, chk_filesystem.sh, chk_messages.sh which are skipped by default); add --no-metrics flag (skips chk_metrics.sh); backward-compatible bare positional argument still accepted; startup banner logs active flags; man/man1/runchk.1 and man/man7/hcpcs-health-check.7 updated to reflect new interface.

### SHA256
```
1563211186d12a4932a46069f98b04bb7c59f40b4a8b0998aa0afc8a8b34cd45  process_health_v1.1.56.tar.xz
```

## v1.1.55
- chk_filesystem.sh: remove LV active+open check — LV state warnings are no longer reported; LVM section now checks PV allocatable flag and VG free space only.

### SHA256
```
d2c49c31d36ee64f1b36051c21d37ce214d8367e3c7418e7081182c2a91caa3b  process_health_v1.1.55.tar.xz
```

## v1.1.54
- chk_messages.sh: limit scope to last 30 days — entries older than the cutoff date are skipped in both error and warning passes (short-format "Mon DD" dates are converted to YYYY-MM-DD using current year, rolling back one year when log month exceeds current month); consolidate multiple journal files per node — all files mapping to the same node name are processed together in a single awk pass so only one screen summary line is emitted per node; remove log filenames from screen output (only brief per-node WARNING count lines and final totals appear on screen; full detail remains in health_report_messages.log).

### SHA256
```
d73c9099a315a68d76e5b497b7d53176b424c9fc54b82794685f6904f8cf0690  process_health_v1.1.54.tar.xz
```

## v1.1.53
- chk_messages.sh: reduce screen verbosity — per-error lines are now written to health_report_messages.log only; screen shows one brief WARNING line per affected node (unique pattern count and total occurrences); log file retains full per-node section (=== node ===), per-day deduplicated ERROR lines (date-only, no time), and per-node summary; final totals continue to print to both screen and log.

### SHA256
```
dccd95ee4d3df2846cf76ee273e1e9766da1204aa8851709eff49850dca21de6  process_health_v1.1.53.tar.xz
```

## v1.1.52
- Add man pages: hcpcs-health-check(7) five-step workflow overview; expand_hcpcs_support(1) full reference; gsc_prometheus(1) full reference; runchk(1) full reference; installed under /usr/local/share/man/man1/ and /usr/local/share/man/man7/.

### SHA256
```
5442604fcd22d8fa455a290a8a948528fbddca94e490264d952ded1b51ba7606  process_health_v1.1.52.tar.xz
```

## v1.1.51
- print_node_memory_summary.sh: add Section 2 — runtime memory pressure from collected free(1) output (*free*.out); per-node table (Total/Used/Avail/Avail%/SwapUsed); WARNING available <20% of total, CRITICAL <10%; WARNING any swap in use, CRITICAL swap >10% of total; unit auto-detection handles free -m (MiB integers), free -h (G/M/K/B suffixes), free -k (large KiB integers heuristic: >2,000,000); fallback for older free without "available" column (RHEL 6/7); results written to health_report_node_memory.log (picked up by runchk.sh issue aggregation); Section 1 lsmem hardware capacity unchanged (ref: free(1) man7.org; Red Hat RHEL8 monitoring memory usage; Red Hat KB 406773 /proc/meminfo; Brendan Gregg USE Method memory saturation).

### SHA256
```
b5b56cb8c174842d09b31611fb31262d350bae0f8c02c40469437e303217f252  process_health_v1.1.51.tar.xz
```

## v1.1.50
- chk_messages.sh: replace per-line error output with per-day deduplication — repeated journal error messages are now collapsed by (day, normalised message key) and reported as a single line with an occurrence count; sort order is day ascending, count descending within each day; message key normalisation strips volatile tokens before grouping: PIDs process[1234]→process[N], hex kernel addresses 0xffff...→0xN, numeric exit/error codes Exited(137)→Exited(N); summary updated to show unique pattern count and total occurrences separately; MSG_MAX_ERRORS limit removed (no longer needed); warning pass unchanged (individual lines written to messages_warn.log).

### SHA256
```
bd36ec9f1b902b51b2790646468c701c157d4f6477a109f5796e8eeecde8a3f4  process_health_v1.1.50.tar.xz
```

## v1.1.49
- Add chk_messages.sh: parses collected journald log files (*journal*.out) per node; classifies lines by syslog priority — ERROR (priorities 0–3: emerg/alert/crit/err patterns: error, failed, failure, BUG:, panic, oom-kill, emerg, crit:, Call Trace, segfault, I/O error, MCE hardware) are printed to screen and written to health_report_messages.log; WARNING (priority 4: warning/warn:, degraded, deprecated, timeout) written to messages_warn.log only; screen output capped at MSG_MAX_ERRORS (default 50) per node, full list always in log file (ref: journalctl(1) man7.org; Red Hat RHEL 8 Viewing and Managing Log Files; Red Hat KB Article 4177861).
- runchk.sh: wire in chk_messages.sh after chk_filesystem.sh.

### SHA256
```
26b64dfd701739c0f0e582b2263ff4376db235677f0e8cfec02d09ca2c3de1b2  process_health_v1.1.49.tar.xz
```

## v1.1.48
- Add chk_docker.sh: parses collected Docker diagnostics per node (*_dockerinfo_docker-v.out, docker-ps-a, inotify, ulimit-Ha); WARNING on Docker major version < 25 (EOL), exited/stale containers, inotify max_user_instances < 8192, numeric max locked memory hard limit (mlock constraint for Kafka/ES); raw output written to docker.log.
- Add chk_disk_perf.sh: parses collected iostat extended output (*iostat*.out); averages r/s, w/s, rkB/s, wkB/s, await, aqu-sz, %util across all intervals per device per node; WARNING %util >75%, CRITICAL >90%; WARNING await >20ms, CRITICAL >100ms; WARNING queue depth >=8 (ref: Red Hat RHEL 8 Performance Tuning Guide; Brendan Gregg USE method).
- Add chk_filesystem.sh: parses collected df (*_diskinfo_df-h*.out), lsblk (*_diskinfo_lsblk*.out), and LVM pvs/vgs/lvs (*_diskinfo_pvs/vgs/lvs*.out); WARNING filesystem Use% >75%, CRITICAL >90%; cross-node mount-point layout diff (missing/extra mounts flagged); LVM exceptions only: PVs not allocatable, VGs with <10% free, LVs not active+open (ref: Red Hat Managing File Systems; Red Hat Configuring and Managing Logical Volumes).
- runchk.sh: wire in chk_docker.sh, chk_disk_perf.sh, chk_filesystem.sh after chk_top.sh.

### SHA256
```
764ee3943b2e898f62ce0f5ba5b31413e090f594e28b8578583175e7e6ded742  process_health_v1.1.48.tar.xz
```

## v1.1.47
- Add chk_top.sh: parses collected top batch output files (top -b -d1 -n30); averages CPU fields (us/sy/id/wa) across all 30 iterations; thresholds for load average (warn >20, crit >40), CPU idle (warn <20%, crit <10%), iowait (warn >10%, crit >20%), memory used % (warn >80%, crit >90%), swap in use (warn), zombies (warn); raw output written to top.log (ref: man7.org/linux/man-pages/man1/top.1.html).
- runchk.sh: wire in chk_top.sh before chk_alerts.sh.

### SHA256
```
58c63c12636abaad2b8caf7f4442c74eef62c36e4be2523bdb23a8cc9795529c  process_health_v1.1.47.tar.xz
```

## v1.1.46
- chk_lshw.sh: log all raw lshw detail per node to lshw.log; print per-node breakdown to screen for each mismatch (WARNING prefix); add NOTICE advice for mixed CPU (standardise hardware, complete refresh before production), mixed memory (capacity imbalance risk), and mixed NICs (verify bonding/throughput consistency).

### SHA256
```
9939865cf624686d4d24dd717c848e9534d197644d43c3039ee9e9b3766482c7  process_health_v1.1.46.tar.xz
```

## v1.1.45
- Add chk_lshw.sh: parses collected lshw hardware inventory files; produces per-node table (memory, NICs, CPU model, sockets, DIMMs populated/total, disk); WARNING on mixed CPU models, memory sizes, or NIC counts across nodes (ref: linux.die.net/man/1/lshw).
- runchk.sh: wire in chk_lshw.sh before chk_chrony.sh.

### SHA256
```
73df393cc52a27cb686c44aefcc146f3c268db00717c78638e621bc4b788b5fb  process_health_v1.1.45.tar.xz
```

## v1.1.44
- Add chk_chrony.sh: checks chrony NTP source reachability across all cluster nodes; ERROR if any source unreachable or degraded (reach != 377); WARNING if valid sources < 4 (per RH #58025 and NTP.org §5.3.3 minimum); detailed raw output written to chronyc.log.
- runchk.sh: wire in chk_chrony.sh before chk_alerts.sh.

### SHA256
```
efd9db302465ba09b9456f3437766245fb20c4ca598e0472974e01601819683f  process_health_v1.1.44.tar.xz
```

## v1.1.43
- hcpcs_parse_partitions_map.sh: fix Partition Count using nodesLeaderFirst[] (all replica positions) instead of nodesLeaderFirst[0]; with replication factor 10 this caused counts to be 10× too high (e.g. 26190 instead of 2619).
- chk_partInfo.sh: print quarterly partition split growth to screen; all detail (yearly/quarterly/monthly/weekly) continues to be written to log file.

### SHA256
```
c40259857e32baafb1be06f6b4dfcb9b4ac9ab669f965c66b7eff9c3aa1ea27f  process_health_v1.1.43.tar.xz
```

## v1.1.42
- gsc_core.sh: uniform 10-char bracket labels for all log levels; add CRITICAL (bright red) and NOTICE (cyan) levels; ERROR is now bold red; all labels padded: [INFO    ] [NOTICE  ] [WARNING ] [ERROR   ] [CRITICAL] [ OK     ]; bump gsc_core version 1.9.0 → 1.9.1.
- gsc_core.sh: gsc_loga() routes WARNING/ERROR/CRITICAL/NOTICE/INFO: prefixes through _gsc__log_line for consistent colored bracket output; raw prefix stripped from screen display.
- gsc_core.sh: log2()/log2a() legacy HCPCS functions route stdout through _gsc__log_line INFO for uniform screen output.
- chk_metrics.sh: replace bare echo "ERROR: ..." with gsc_log_error for consistent formatting.

### SHA256
```
be3c470b71209fb6447fdbb903fcf8b1c28bd8d157f8accc6b59124659e34223  process_health_v1.1.42.tar.xz
```

## v1.1.41
- Terse display: runchk.sh now shows only high-level summary and issues on screen; all detail data (partition tables, service lists, split growth breakdown, per-node thresholds) is written to log files only.
- gsc_core.sh: change gsc_loga() so that when _output_file is set, detail lines go to file only; WARNING/ERROR/CRITICAL/NOTICE/INFO: prefixed lines still echo to screen.
- chk_partInfo.sh: separate partition-per-node table from its label so table data goes to file only.
- hcpcs_parse_partitions_map.sh: remove echo/paste of partition count table (data already in log file); change "Created" message to gsc_log_info.
- hcpcs_parse_partitions_state.sh: replace plain echo calls with gsc_log_info.
- parse_instances_info.sh: replace plain echo calls with gsc_loga/gsc_log_info so they go to file only or display as progress.

### SHA256
```
15213d6da89ffefc4e672b43b78e523a48581d7821204fa4901c850a6a3a816e  process_health_v1.1.41.tar.xz
```

## v1.1.40
- Fix hcpcs_parse_partitions_map.sh: deduplicate partition entries by partition ID before counting (partition map is built from 10 files; without deduplication counts were 10× too high, e.g. 26190 instead of 2619).
- Fix chk_cluster.sh: add gsc_rotate_log at startup so health_report_cluster.log is cleared on each run (missing rotation caused every line to be duplicated in the final issue summary).
- Add print_node_os_summary.sh: source os.conf (if present) and warn when any node group is running an OS version older than _current_os.
- Add os.conf: configurable current OS version reference (_current_os="8.10").

### SHA256
```
5fded9c46e8a7cc6a8c7c05d23f4442f54464223bc16d06d05480af8463a6dcf  process_health_v1.1.40.tar.xz
```

## v1.1.39
- Refactor: standardize all user-defined variables to `_lowercase_underscore` prefix across 23 scripts (all chk_*.sh, partition/data scripts, runchk.sh, gsc_grafana.sh, hcpcs_lib.sh, healthcheck.conf).
- Extend gsc_core.sh with new shared helpers: `gsc_loga` (tee to log + stdout), `gsc_log_debug` (conditional debug), `gsc_find_file`, `gsc_is_empty`, `gsc_is_number`, `gsc_is_float`, `gsc_is_json`; bump version 1.8.31 → 1.9.0.
- Consolidate duplicated helper functions (debug, loga, isEmpty, isNumber, isFloatNumber, progress, find_file_by_shortname) from individual scripts into gsc_core.sh; remove duplicates from chk_collected_metrics.sh, chk_metrics.sh, chk_buckets.sh, chk_snodes.sh, parse_instances_info.sh.
- Fix get_partition_info.sh: add missing gsc_core.sh sourcing (script called gsc_truncate_log without sourcing the library).

### SHA256
```
7f51e09107fa2d3bae5acf262572c8120cd182e1f347ae4c2068e664766b454b  process_health_v1.1.39.tar.xz
```

## v1.1.38
- Add chk_partInfo.sh: chk_partition_split_growth() function; finds all *splitpartition.json files under the log directory, deduplicates events by parentId across multiple collection runs, and reports partition splits per week (top 10 busiest), month, quarter, and year.

### SHA256
```
bb0b0080c9330f6eb6ef2675c71405b04d99f6806a063fb3a0531a793516bc02  process_health_v1.1.38.tar.xz
```

## v1.1.37
- Fix runchk.sh: add CRITICAL to issue summary grep so CRITICAL-level findings (e.g. partition count) are counted and listed in the final report.

### SHA256
```
5c6f11208a03bc6abbfe1cdb371e9c3b703f53a1429ad7f63c919dd18be641b7  process_health_v1.1.37.tar.xz
```

## v1.1.36
- Fix runchk.sh: wire chk_partInfo.sh into the main run sequence after get_partition_tool_info.sh so partition count and split threshold checks appear in the issue summary.
- Fix chk_partInfo.sh: change state-file completeness guard from exit to warning so partition count and split threshold checks run even when state data is incomplete.

### SHA256
```
1311868ab210de65dd0c4182423b3be7b5a4134f3c830ddccdc11d3ead167f7a  process_health_v1.1.36.tar.xz
```

## v1.1.35
- Fix chk_partInfo.sh: add partition split threshold check; finds all *split*.out files under the log directory, deduplicates across multiple collection runs, sorts by service and threshold, and reports each node's configured split size with the largest value highlighted.

### SHA256
```
686206e7e73021ff193860f9649ca14f346fd4cc1e4fab943e878c44cbce45f9  process_health_v1.1.35.tar.xz
```

## v1.1.34
- Fix chk_partInfo.sh: align partition-per-node severity labels to spec (normal <1000 prints OK, high >1000 WARNING, dangerous >1500 DANGEROUS, critical >2000 CRITICAL); add per-node IP and count to each violation message; fix typo EXTREMLY → EXTREMELY.
- Fix hcpcs_hourly_alerts.json A00012: raise Error threshold from >1500 to >2000 (critical); update Description to document all four severity levels; add comment noting dangerous (>1500) is checked offline by chk_partInfo.sh.

### SHA256
```
6dbce1e9da0714461d86a0b017c8906a7cab0a59fd498f6460b1f1891c3591a5  process_health_v1.1.34.tar.xz
```

## v1.1.33
- Add chk_service_placement.sh: detect data-plane services (Metadata-Gateway, S3-Gateway, Data-Lifecycle) co-located on master nodes (those running Service-Deployment); reports each violation in red via gsc_log_error with advice to move the service off the master.
- Update runchk.sh: call chk_service_placement.sh after prep_services_instances.sh; violations are included in the final issue summary.

### SHA256
```
c0f55dd9584b944389bf5f76a7c3592a3b30da74080e9d43d44c75ee202fbf2f  process_health_v1.1.33.tar.xz
```

## v1.1.32
- Fix hcpcs_parse_partitions_map.sh: add `.[] |` before `.entryMapping` in all four jq queries; partitionMap.json is a slurped array of N documents so indexing `.entryMapping` on the array root produced "Cannot index array with string" errors.
- Fix chk_metrics.sh: source gsc_core.sh and replace manual `mv ... .bak` rotation in setLogFile() with gsc_rotate_log (2 timestamped backups); remove redundant pre-rotation block before setLogFile call.

### SHA256
```
1276262438a0e76df8548da072b47472b6a561f4f467dab53babe3d9f73ae782  process_health_v1.1.32.tar.xz
```

## v1.1.31
- Fix gsc_core.sh (gsc_check_extract_space): guard at line 525 checked _fs_total was numeric but not non-zero; division at line 531 would crash with an arithmetic error on filesystems where df reports 0 total (e.g. unlimited tmpfs). Add -ne 0 check, matching the existing guard in sibling gsc_print_space_estimate.

## v1.1.30
- Fix services_sh_25/coordination.sh, services_sh_25/data-lifecycle.sh: missing newline at end of file (POSIX violation); _26 counterparts already had the trailing newline.

### SHA256
```
5d25f159c7538089a9e609de587f4a0ecc572ab750820eb57d97e179e712c390  process_health_v1.1.30.tar.xz
```

## v1.1.29
- Fix generate_healthcheck.sh: _cs_version auto-detection ran under set -euo pipefail with a misplaced redirect; script aborted at startup if chk_cluster.sh was not in PATH or failed. Move 2>/dev/null inside the subshell and add || true to make auto-detection non-fatal.
- Fix generate_healthcheck.sh: _prom_time_stamp never initialised; write_full_config() caused an unbound variable abort under set -u when -P was not passed. Initialise to empty string.
- Fix runchk.sh: "issuess:" typo in user-facing log output.

### SHA256
```
88912e3ac85fd4ef21291d5dc5ace35d1bbd8a32f4ac9419138e1edb2f61e483  process_health_v1.1.29.tar.xz
```

## v1.1.28
- Fix parse_instances_info.sh: -s flag set INPUT_SHORTNAME_FILE (typo) instead of INPUT_FILE_SHORTNAME; shortname override had no effect and the script always searched using the default filename.
- Fix collect_metrics.sh: convert AUTH from a word-split string to a proper bash array so the curl -u flag and value are separate array elements without relying on unquoted word splitting.

### SHA256
```
edc732cab45ad68dda59979949fd2447c665932abd932d017cddf235de55b47d  process_health_v1.1.28.tar.xz
```

## v1.1.27
- Fix collect_metrics.sh: AUTH built as "user:pass" without the curl -u flag; curl received credentials as a positional URL argument, silently breaking authentication. Prepend -u so the flag+value pair is correct.
- Fix parse_instances_info.sh: $clusterName referenced in log header but never assigned; always expanded to empty string. Replace with $INPUT_JSON_FILE.
- Fix chk_services_memory.sh: -f and -F flags parsed into INPUT_FILE_SERVICE / INPUT_FILE_NODE but those variables were never read; full-path override silently did nothing. Initialise vars and wire them into the file-finding logic.

### SHA256
```
225d58de3a02175f2dc050b6c7914d71f234508a7d5d4a6f8aaf5c84632a0737  process_health_v1.1.27.tar.xz
```

## v1.1.26
- Fix chk_collected_metrics.sh, chk_metrics.sh, collect_metrics.sh: replace let num_queries=0 with plain assignment; let returns exit code 1 when the result is 0, which would kill the script under errexit.
- Fix Makefile: add --exclude='*.tar.xz' --exclude='*.sha256' to the bundle target so previously built archives are not included in new bundles.

### SHA256
```
127f12c192787db5c92fd7cd72027f529fba3f748fc7e6917f17c2c2ec17e17c  process_health_v1.1.26.tar.xz
```

## v1.1.25
- Fix services_sh_25/data.sh, services_sh_26/data.sh: quote $TOMCAT_TMP in rm -rf and mkdir -p to prevent word splitting if SERVICE_DATA_DIR is empty.
- Fix dls_get_all_logs.sh: add xargs -d '\n' so filenames with spaces are not word-split when concatenating log files.

### SHA256
```
23864487bbdff6c9660a387b55bb01847ed8216fb256cc9b45712bd0230e09e8  process_health_v1.1.25.tar.xz
```

## v1.1.24
- Fix hcpcs_parse_partitions_map.sh: replace deprecated egrep with grep -E.
- Fix hcpcs_parse_partitions_state.sh: add -r to read to prevent backslash mangling in property file lines.
- Fix dls_get_all_logs.sh: add explicit . path to find for portability.

### SHA256
```
18b0e6e23055992f4eed01bccc5091d23c22ad0c8a4b8ed7e2e89239cc682820  process_health_v1.1.24.tar.xz
```

## v1.1.23
- Fix services_sh_25/service-funcs.sh: shebang was on line 4 (after a comment) instead of line 1; moved to first line so bash recognises it correctly.
- Fix chk_metrics.sh: add missing o: to getopts string so -o OUTPUT_FILE_PREFIX flag is reachable.
- Fix chk_metrics.sh: unquoted values+=($value) replaced with values+=("$value") to prevent word splitting.
- Fix detect_app_per_bucket.sh: printf '%*s' "$nspaces" missing second argument; add empty string so width is applied correctly.
- Fix dls_get_all_logs.sh: add || exit 1 guards to pushd, cd, and popd; replace fragile `ls -d */` with glob; fix ${dirname} (unassigned) to ${ALL_DLS_DIR} so the output directory is correctly skipped during iteration.
- Fix services_sh_25/rabbitMQServer.sh, services_sh_26/rabbitMQServer.sh: quote erlang cookie subshell in echo to prevent word splitting; split export RABBITMQ_NODENAME to avoid masking exit code; split local val assignment to avoid masking exit code; replace backtick with $() and quote erl version subshell.
- Fix services_sh_25/common.sh, services_sh_26/common.sh: split local TIMESTAMP assignment to avoid masking exit code.

### SHA256
```
0c9d62df8a4ccdfd14cb33df435b822906a20d98f1c910818f0e9b04135b1a73  process_health_v1.1.23.tar.xz
```

## v1.1.22
- Fix chk_collected_metrics.sh: unquoted values+=($value) replaced with values+=("$value") to prevent word splitting on metric values containing spaces.
- Fix chk_collected_metrics.sh: remove permanently dead elif branch testing value_minmax_json (assignment was commented out; branch could never execute).
- Fix parse_partInfo_keyspaces.sh: add || exit 1 guard to cd so script fails clearly if directory argument is invalid.
- Fix services_sh_25/cassandra.sh, services_sh_26/cassandra.sh: split export CASSANDRA_DATA_HOME=$(escape_spaces ...) into assign then export to avoid masking subshell exit code.
- Fix services_sh_25/chronos.sh, services_sh_26/chronos.sh: quote $($SERVICE_TOOLS_DIR/localIp.sh) in exec args to prevent word splitting.

### SHA256
```
109480edcb6ff25fde84ea5ddce053c128c1acbd7af8049dc34bbbdfa12adffd  process_health_v1.1.22.tar.xz
```

## v1.1.21
- Fix gen_collection_def.sh, gen_telemetry_def.sh: mv used unassigned $output_file instead of $log_file for backup — backup was silently written to wrong path.
- Fix services_sh_25/rabbitMQServer.sh, services_sh_26/rabbitMQServer.sh: grep -v used $RABBIT_ADMIN_USER (unassigned) instead of $RABBITMQ_ADMIN_USER — admin credentials were not redacted from logged config output.

### SHA256
```
99a30a1e62d8cb258f77f45ad3a699fc5d896ad1a7818b1d8f176f800ab8897f  process_health_v1.1.21.tar.xz
```

## v1.1.20
- Fix gsc_core.sh: add * fallback to getOptions() to warn and exit on unknown flags.
- Fix detect_app_per_bucket.sh: replace let max=$2 with parameter expansion guard to fail clearly on missing argument.
- Fix parse_instances_info.sh: remove duplicate d) case in getopts (dead code); remove duplicate d from getopts string.
- Fix print_node_os_summary.sh: add :-0 default to associative array lookup inside $(( )) to guard against unset key.
- Fix chk_cluster.sh, cp_all.sh: add missing #!/usr/bin/env bash shebang.
- Fix services_sh_25/common.sh, services_sh_25/service-funcs.sh, services_sh_26/common.sh, services_sh_26/service-funcs.sh: add missing #!/usr/bin/env bash shebang.

## v1.1.19
- Fix dls_log_parse.sh: unclosed $(...) on all awk substitutions, unclosed " on echo, and unclosed (( on jobs++ — script was entirely broken and could not execute.
- Fix gsc_core.sh: guard against divide-by-zero on _fs_total in gsc_print_space_estimate.
- Fix gsc_grafana.sh: [[ -n "_url" ]] was testing a literal string instead of $\_url — download branch now correctly gated.
- Fix chk_metrics.sh: string < comparison on epoch integers replaced with -lt.
- Fix chk_metrics.sh: echo "mycmd=${mycmd[@]}" array re-splitting; use ${mycmd[*]}.
- Fix collect_metrics.sh: string < comparisons on epoch integers replaced with -lt.
- Fix collect_metrics.sh: echo "mycmd=${mycmd[@]}" array re-splitting; use ${mycmd[*]}.
- Fix chk_partInfo.sh: string > comparison on numeric error count replaced with -gt.
- Fix dls_get_all_logs.sh: shebang #/bin/bash corrected to #!/bin/bash.
- Fix kafka-server-start.sh (services_sh_25 + services_sh_26): quote "$@" in exec to prevent argument re-splitting.

## v1.1.18
- Bump version to v1.1.18.
- Tag v1.1.17 closed; v1.1.18 marked as latest release.

### SHA256
```
217af179a296eb989ac8dc2a7483500339ceb21e8c37d1bc9d5a70dce4430006  process_health_v1.1.18.tar.xz
```

## v1.1.17
- Rewrite README.md with full usage, configuration, script reference, and partition growth tool documentation.
- Update Makefile to derive bundle name from VERSION file (produces process_health_<version>.tar.xz).
- Consolidate gsc_library.sh into gsc_core.sh as the single source of truth for all shared functions; gsc_library.sh retained as a compatibility shim. All scripts updated to source gsc_core.sh directly.

### SHA256
```
b4f60694c4753b482da72bef5a92b2c473b49156c17f7b4deb0470b27da6343c  process_health_v1.1.17.tar.xz
```

## v1.1.16
- Fix bash syntax error in partition artifact parser logging; use gsc_rotate_log() + tee with clean newlines.
- Partition parser logs rotated with keep=2 via unified function.

## v1.1.15
- Add unified log rotation helpers: gsc_rotate_log() and gsc_truncate_log() (keep 2 backups).
- Update gsc_library.sh to rotate logs instead of single .bak.
- Replace direct log truncation (': > file') in scripts with gsc_truncate_log for consistent retention.

## v1.1.14
- Add retention cleanup for partition parser logs: keep only 2 timestamped backups per log.

## v1.1.13
- Add automatic timestamped backup of partitionMap_parse.log and partitionState_parse.log before overwrite.

## v1.1.12
- Stream partition parser output to screen and save logs via tee:
  - supportLogs/partitionMap_parse.log
  - supportLogs/partitionState_parse.log
- Selfcheck now verifies 'tee' dependency.

## v1.1.11
- Ensure gsc_prep_partition_artifacts_and_parse runs partition map parser with mp-preference and prints output to screen.

## v1.1.10
- Update partition prep to write artifacts under supportLogs/: partitionMap.json, partitionState.json, partitionStateProperties.txt.
- Seed properties extracted from *seed*.json into supportLogs/partitionStateProperties.txt.
- Map parser prefers hcpcs_parse_partitions_mp.sh if present, else hcpcs_parse_partitions_map.sh.

## v1.1.9
- Fix partition parser execution paths: call parsers via bundle directory instead of current working directory.
- Clean up warning text (no duplicate '(or ...)').

## v1.1.8
- Remove all residual mp references (use hcpcs_parse_partitions_map.sh only).
- Add selfcheck.sh and run it at start of runchk.sh.
- Flatten release: ZIP contains full source tree (no nested tar).

## v1.1.7
- Simplify partition parser log message to reference hcpcs_parse_partitions_map.sh only.

## v1.1.6
- Use hcpcs_parse_partitions_map.sh as primary partition map parser (fallback to hcpcs_parse_partitions_mp.sh).

## v1.1.5
- Fix partition parser invocation: use hcpcs_parse_partitions_mp.sh and ensure partition parser scripts are executable; add fallback to *_map.sh.

## v1.1.4
- Fix gsc_require not found by ensuring bundle-local gsc_core.sh is sourced and adding gsc_require helper.

## v1.1.2
- Add partition JSON prep function (map/state) and helper script.

# Changelog

## v1.0.12 - Core runtime + Prometheus unification

- Add `gsc_core.sh` core runtime (logging, dependency checks, safe tar extraction, container helpers).
- Add `gsc_prometheus.sh` unified Prometheus snapshot extractor/runner.
- Keep legacy wrappers `gsc_container_prometheus.sh` and `gsc_docker_prometheus.sh`.
- Default Prometheus image set to fully-qualified `docker.io/prom/prometheus:latest` to avoid Podman short-name registry errors.
- Add Makefile + GitHub Actions CI workflow for `bash -n` + `shellcheck`.

## v1.0.11 - JSON helper fix

- Fix stray anonymous function in `hcpcs_lib.sh` that caused syntax errors.
- Use `hcpcs_json_body_from_file()` + `hcpcs_json_is_valid()` for safe JSON parsing of partition map files.
