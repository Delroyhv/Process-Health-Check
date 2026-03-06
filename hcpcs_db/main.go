package main

// hcpcs_db — stores and queries health-check run results in a SQLite database.
//
// Commands:
//   record  [flags]    Scan health_report*.log in cwd and insert a run record.
//   list    [flags]    Show recent runs as an aligned table.
//   show    <id>       Show all issues for one run.
//   trend   <sr>       Show per-run severity counts for one SR over time.
//
// Environment:
//   HCPCS_DB=<path>   Default database path (used when --db is not specified).
//                     The file and its parent directory are created if absent.
//
// Default path when HCPCS_DB is unset: ~/.local/share/hcpcs/results.db

import (
	"bufio"
	"database/sql"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	_ "modernc.org/sqlite"
)

// ── Schema ───────────────────────────────────────────────────────────────────

const schema = `
CREATE TABLE IF NOT EXISTS runs (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    ts             TEXT    NOT NULL,
    run_dir        TEXT    NOT NULL,
    sr_number      TEXT    NOT NULL DEFAULT '',
    customer       TEXT    NOT NULL DEFAULT '',
    cs_version     TEXT    NOT NULL DEFAULT '',
    node_count     INTEGER NOT NULL DEFAULT 0,
    elapsed_sec    INTEGER NOT NULL DEFAULT 0,
    critical_count INTEGER NOT NULL DEFAULT 0,
    danger_count   INTEGER NOT NULL DEFAULT 0,
    error_count    INTEGER NOT NULL DEFAULT 0,
    warning_count  INTEGER NOT NULL DEFAULT 0,
    action_count   INTEGER NOT NULL DEFAULT 0,
    issues_total   INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS issues (
    id       INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id   INTEGER NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
    severity TEXT    NOT NULL,
    source   TEXT    NOT NULL DEFAULT '',
    message  TEXT    NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_issues_run ON issues(run_id);
CREATE INDEX IF NOT EXISTS idx_runs_ts    ON runs(ts DESC);
CREATE INDEX IF NOT EXISTS idx_runs_sr    ON runs(sr_number);
`

// ── Issue scanning ───────────────────────────────────────────────────────────

// noisePatterns mirrors runchk.sh _issues_filter (lines excluded from summary).
var noisePatterns = []*regexp.Regexp{
	regexp.MustCompile(`: source \S+ (?:unreachable|degraded)`),
	regexp.MustCompile(`: only \d+ of \d+ source.s. fully reachable`),
	regexp.MustCompile(`^\s*\d+ [\d.]+\s*\[(?:CRITICAL|WARNING|DANGER|good)\]`),
	regexp.MustCompile(`^\s*(?:\d+-\d+|>=\s*\d+)\s*:\s*\[(?:WARNING|DANGER|CRITICAL|good)\]`),
}

var issueLine = regexp.MustCompile(`ERROR|WARNING|CRITICAL|DANGER|ACTION|ALERT`)

type issue struct {
	severity string
	source   string
	message  string
}

func isNoise(line string) bool {
	for _, re := range noisePatterns {
		if re.MatchString(line) {
			return true
		}
	}
	return false
}

func severityOf(line string) string {
	switch {
	case strings.Contains(line, "CRITICAL") || strings.Contains(line, "ALERT"):
		return "CRITICAL"
	case strings.Contains(line, "DANGER"):
		return "DANGER"
	case strings.Contains(line, "ERROR"):
		return "ERROR"
	case strings.Contains(line, "WARNING"):
		return "WARNING"
	case strings.Contains(line, "ACTION"):
		return "ACTION"
	}
	return ""
}

// scanIssues reads all health_report*.log files in dir and returns matched issues.
func scanIssues(dir string) ([]issue, error) {
	pattern := filepath.Join(dir, "health_report*.log")
	files, err := filepath.Glob(pattern)
	if err != nil {
		return nil, err
	}
	sort.Strings(files)

	var result []issue
	for _, path := range files {
		// health_report_messages.log is excluded (legacy; its entries duplicate others)
		if strings.HasSuffix(path, "health_report_messages.log") {
			continue
		}
		source := filepath.Base(path)
		f, err := os.Open(path)
		if err != nil {
			continue
		}
		sc := bufio.NewScanner(f)
		for sc.Scan() {
			line := sc.Text()
			if !issueLine.MatchString(line) {
				continue
			}
			if isNoise(line) {
				continue
			}
			sev := severityOf(line)
			if sev == "" {
				continue
			}
			result = append(result, issue{severity: sev, source: source, message: strings.TrimSpace(line)})
		}
		f.Close()
	}
	return result, nil
}

// ── Cluster info parsing ─────────────────────────────────────────────────────

var reVersion = regexp.MustCompile(`(?i)(?:product version|HCP-CS version:?)\s+([\d.]+)`)
var reNodeCount = regexp.MustCompile(`(\d+)\s+nodes?`)
var reParseInstances = regexp.MustCompile(`\((\d+)\s+nodes?,`)

func parseClusterInfo(dir string) (version string, nodeCount int) {
	// cs_version: health_report_cluster.log
	if f, err := os.Open(filepath.Join(dir, "health_report_cluster.log")); err == nil {
		sc := bufio.NewScanner(f)
		for sc.Scan() {
			if m := reVersion.FindStringSubmatch(sc.Text()); m != nil {
				version = m[1]
				break
			}
		}
		f.Close()
	}
	// node_count: hcpcs_services_info.log has "[INFO ] parse_instances: wrote ... (14 nodes, 30 services)"
	// or "N nodes" as a standalone line
	if f, err := os.Open(filepath.Join(dir, "hcpcs_services_info.log")); err == nil {
		sc := bufio.NewScanner(f)
		for sc.Scan() {
			line := sc.Text()
			// parse_instances binary output: "(14 nodes, 30 services)"
			if m := reParseInstances.FindStringSubmatch(line); m != nil {
				if n, e := strconv.Atoi(m[1]); e == nil {
					nodeCount = n
					break
				}
			}
			// fallback: "14 nodes" standalone
			if m := reNodeCount.FindStringSubmatch(line); m != nil {
				if n, e := strconv.Atoi(m[1]); e == nil && nodeCount == 0 {
					nodeCount = n
				}
			}
		}
		f.Close()
	}
	return
}

// inferSR extracts an SR number from the run directory path.
// Looks for an 8-digit directory component (e.g. /ci/05448336/2026-02-14.../cwd).
var reSR = regexp.MustCompile(`\b(\d{8})\b`)

func inferSR(dir string) string {
	// Walk path components from deepest to root looking for an 8-digit segment
	parts := strings.Split(filepath.Clean(dir), string(os.PathSeparator))
	for i := len(parts) - 1; i >= 0; i-- {
		if m := reSR.FindString(parts[i]); m != "" {
			return m
		}
	}
	return ""
}

// ── Database helpers ─────────────────────────────────────────────────────────

func defaultDBPath() string {
	if v := os.Getenv("HCPCS_DB"); v != "" {
		return v
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".local", "share", "hcpcs", "results.db")
}

func openDB(path string) (*sql.DB, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0750); err != nil {
		return nil, fmt.Errorf("create db dir: %w", err)
	}
	db, err := sql.Open("sqlite", path+"?_pragma=foreign_keys(1)&_pragma=journal_mode(WAL)")
	if err != nil {
		return nil, err
	}
	if _, err := db.Exec(schema); err != nil {
		db.Close()
		return nil, fmt.Errorf("schema: %w", err)
	}
	return db, nil
}

// ── Commands ──────────────────────────────────────────────────────────────────

func cmdRecord(args []string) error {
	fs := flag.NewFlagSet("record", flag.ExitOnError)
	dbPath   := fs.String("db", defaultDBPath(), "Database path")
	dir      := fs.String("dir", ".", "Directory containing health_report*.log files")
	sr       := fs.String("sr", "", "SR number (auto-inferred from path if omitted)")
	customer := fs.String("customer", "", "Customer name")
	version  := fs.String("version", "", "HCP-CS version (auto-parsed if omitted)")
	elapsed  := fs.Int("elapsed", 0, "Elapsed seconds (from runchk.sh)")
	fs.Parse(args)

	absDir, err := filepath.Abs(*dir)
	if err != nil {
		return err
	}

	// Cluster info (auto-parse from logs if not provided)
	parsedVersion, nodeCount := parseClusterInfo(absDir)
	if *version == "" {
		*version = parsedVersion
	}
	if *sr == "" {
		*sr = inferSR(absDir)
	}

	// Scan issues
	issues, err := scanIssues(absDir)
	if err != nil {
		return fmt.Errorf("scan issues: %w", err)
	}

	// Count by severity
	counts := map[string]int{"CRITICAL": 0, "DANGER": 0, "ERROR": 0, "WARNING": 0, "ACTION": 0}
	for _, iss := range issues {
		counts[iss.severity]++
	}
	total := len(issues)

	// Open DB and insert
	db, err := openDB(*dbPath)
	if err != nil {
		return err
	}
	defer db.Close()

	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	ts := time.Now().UTC().Format(time.RFC3339)
	res, err := tx.Exec(`INSERT INTO runs
		(ts, run_dir, sr_number, customer, cs_version, node_count, elapsed_sec,
		 critical_count, danger_count, error_count, warning_count, action_count, issues_total)
		VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)`,
		ts, absDir, *sr, *customer, *version, nodeCount, *elapsed,
		counts["CRITICAL"], counts["DANGER"], counts["ERROR"],
		counts["WARNING"], counts["ACTION"], total)
	if err != nil {
		return fmt.Errorf("insert run: %w", err)
	}
	runID, _ := res.LastInsertId()

	stmt, err := tx.Prepare(`INSERT INTO issues (run_id, severity, source, message) VALUES (?,?,?,?)`)
	if err != nil {
		return err
	}
	for _, iss := range issues {
		if _, err := stmt.Exec(runID, iss.severity, iss.source, iss.message); err != nil {
			return err
		}
	}
	stmt.Close()

	if err := tx.Commit(); err != nil {
		return err
	}

	fmt.Fprintf(os.Stderr, "[INFO ] hcpcs_db: recorded run #%d — %d issues (CRIT:%d DANG:%d ERR:%d WARN:%d ACT:%d) → %s\n",
		runID, total, counts["CRITICAL"], counts["DANGER"], counts["ERROR"],
		counts["WARNING"], counts["ACTION"], *dbPath)
	return nil
}

func cmdList(args []string) error {
	fs := flag.NewFlagSet("list", flag.ExitOnError)
	dbPath := fs.String("db", defaultDBPath(), "Database path")
	limit  := fs.Int("limit", 20, "Maximum number of runs to show")
	sr     := fs.String("sr", "", "Filter by SR number")
	fs.Parse(args)

	db, err := openDB(*dbPath)
	if err != nil {
		return err
	}
	defer db.Close()

	q := `SELECT id, ts, sr_number, customer, cs_version, node_count, elapsed_sec,
	             critical_count, danger_count, error_count, warning_count, action_count, issues_total
	      FROM runs`
	var qargs []interface{}
	if *sr != "" {
		q += " WHERE sr_number = ?"
		qargs = append(qargs, *sr)
	}
	q += " ORDER BY ts DESC LIMIT ?"
	qargs = append(qargs, *limit)

	rows, err := db.Query(q, qargs...)
	if err != nil {
		return err
	}
	defer rows.Close()

	type row struct {
		id, nodes, elapsed, crit, dang, err_, warn, act, total int
		ts, sr, customer, ver                                    string
	}
	var data []row
	for rows.Next() {
		var r row
		if e := rows.Scan(&r.id, &r.ts, &r.sr, &r.customer, &r.ver, &r.nodes, &r.elapsed,
			&r.crit, &r.dang, &r.err_, &r.warn, &r.act, &r.total); e != nil {
			return e
		}
		// Trim timestamp to readable length
		if len(r.ts) > 19 {
			r.ts = r.ts[:19]
		}
		data = append(data, r)
	}

	if len(data) == 0 {
		fmt.Println("No runs recorded yet.")
		return nil
	}

	// Reverse so oldest-first when there are few rows (makes trend reading easier)
	for i, j := 0, len(data)-1; i < j; i, j = i+1, j-1 {
		data[i], data[j] = data[j], data[i]
	}

	fmt.Printf("%-4s  %-19s  %-10s  %-10s  %-8s  %-5s  %-7s  %-4s  %-4s  %-4s  %-5s  %-4s\n",
		"ID", "Timestamp", "SR", "Customer", "Version", "Nodes", "Elapsed", "CRIT", "DANG", "ERR", "WARN", "ACT")
	fmt.Println(strings.Repeat("-", 103))
	for _, r := range data {
		fmt.Printf("%-4d  %-19s  %-10s  %-10s  %-8s  %-5d  %-7s  %-4d  %-4d  %-4d  %-5d  %-4d\n",
			r.id, r.ts, r.sr, r.customer, r.ver, r.nodes,
			fmt.Sprintf("%ds", r.elapsed),
			r.crit, r.dang, r.err_, r.warn, r.act)
	}
	fmt.Printf("\n%d run(s) shown. Use 'hcpcs_db show <id>' for issue details.\n", len(data))
	return nil
}

func cmdShow(args []string) error {
	fs := flag.NewFlagSet("show", flag.ExitOnError)
	dbPath := fs.String("db", defaultDBPath(), "Database path")
	fs.Parse(args)

	if fs.NArg() < 1 {
		return fmt.Errorf("usage: hcpcs_db show <run_id>")
	}
	runID, err := strconv.Atoi(fs.Arg(0))
	if err != nil {
		return fmt.Errorf("invalid run id: %s", fs.Arg(0))
	}

	db, err := openDB(*dbPath)
	if err != nil {
		return err
	}
	defer db.Close()

	// Run header
	var ts, runDir, sr, customer, ver string
	var nodes, elapsed, crit, dang, errC, warn, act, total int
	err = db.QueryRow(`SELECT ts, run_dir, sr_number, customer, cs_version, node_count, elapsed_sec,
		critical_count, danger_count, error_count, warning_count, action_count, issues_total
		FROM runs WHERE id=?`, runID).
		Scan(&ts, &runDir, &sr, &customer, &ver, &nodes, &elapsed,
			&crit, &dang, &errC, &warn, &act, &total)
	if err == sql.ErrNoRows {
		return fmt.Errorf("run #%d not found", runID)
	}
	if err != nil {
		return err
	}

	fmt.Printf("Run #%d  |  %s\n", runID, ts)
	fmt.Printf("  SR: %-12s  Customer: %-12s  Version: %s  Nodes: %d  Elapsed: %ds\n",
		sr, customer, ver, nodes, elapsed)
	fmt.Printf("  Dir: %s\n", runDir)
	fmt.Printf("  Issues: %d total  (CRIT:%d  DANG:%d  ERR:%d  WARN:%d  ACT:%d)\n\n",
		total, crit, dang, errC, warn, act)

	if total == 0 {
		fmt.Println("  No issues recorded.")
		return nil
	}

	// Issues ordered by severity priority then source
	rows, err := db.Query(`
		SELECT severity, source, message FROM issues
		WHERE run_id=?
		ORDER BY
		  CASE severity WHEN 'CRITICAL' THEN 1 WHEN 'DANGER' THEN 2
		                WHEN 'ERROR' THEN 3 WHEN 'WARNING' THEN 4
		                WHEN 'ACTION' THEN 5 ELSE 6 END,
		  source, id`,
		runID)
	if err != nil {
		return err
	}
	defer rows.Close()

	curSev := ""
	for rows.Next() {
		var sev, source, msg string
		if e := rows.Scan(&sev, &source, &msg); e != nil {
			return e
		}
		if sev != curSev {
			fmt.Printf("  ── %s ──\n", sev)
			curSev = sev
		}
		fmt.Printf("    [%-8s] %s\n", source, msg)
	}
	return nil
}

func cmdTrend(args []string) error {
	fs := flag.NewFlagSet("trend", flag.ExitOnError)
	dbPath := fs.String("db", defaultDBPath(), "Database path")
	fs.Parse(args)

	if fs.NArg() < 1 {
		return fmt.Errorf("usage: hcpcs_db trend <sr_number>")
	}
	sr := fs.Arg(0)

	db, err := openDB(*dbPath)
	if err != nil {
		return err
	}
	defer db.Close()

	rows, err := db.Query(`
		SELECT id, ts, elapsed_sec, issues_total,
		       critical_count, danger_count, error_count, warning_count, action_count
		FROM runs WHERE sr_number=? ORDER BY ts`, sr)
	if err != nil {
		return err
	}
	defer rows.Close()

	type run struct {
		id, elapsed, total, crit, dang, errC, warn, act int
		ts                                               string
	}
	var data []run
	for rows.Next() {
		var r run
		if e := rows.Scan(&r.id, &r.ts, &r.elapsed, &r.total,
			&r.crit, &r.dang, &r.errC, &r.warn, &r.act); e != nil {
			return e
		}
		if len(r.ts) > 19 {
			r.ts = r.ts[:19]
		}
		data = append(data, r)
	}

	if len(data) == 0 {
		fmt.Printf("No runs found for SR %s.\n", sr)
		return nil
	}

	fmt.Printf("Trend for SR %s (%d run(s)):\n\n", sr, len(data))
	fmt.Printf("%-4s  %-19s  %-7s  %-5s  %-4s  %-4s  %-4s  %-5s  %-4s\n",
		"ID", "Timestamp", "Elapsed", "Total", "CRIT", "DANG", "ERR", "WARN", "ACT")
	fmt.Println(strings.Repeat("-", 72))

	for i, r := range data {
		// Arrow indicator if total improved/degraded since last run
		arrow := "  "
		if i > 0 {
			switch {
			case r.total < data[i-1].total:
				arrow = "↓ "
			case r.total > data[i-1].total:
				arrow = "↑ "
			default:
				arrow = "→ "
			}
		}
		fmt.Printf("%-4d  %-19s  %-7s  %s%-4d  %-4d  %-4d  %-4d  %-5d  %-4d\n",
			r.id, r.ts, fmt.Sprintf("%ds", r.elapsed),
			arrow, r.total, r.crit, r.dang, r.errC, r.warn, r.act)
	}
	return nil
}

// ── main ─────────────────────────────────────────────────────────────────────

func usage() {
	fmt.Fprintln(os.Stderr, `hcpcs_db — Health-check results database

Commands:
  record  [--db PATH] [--dir DIR] [--sr SR] [--customer NAME] [--elapsed N] [--version VER]
          Scan health_report*.log in DIR (default: cwd) and insert a run record.

  list    [--db PATH] [--limit N] [--sr SR]
          Show recent runs as an aligned table.

  show    [--db PATH] <run_id>
          Show all issues for one run.

  trend   [--db PATH] <sr_number>
          Show per-run severity counts for one SR over time.

Environment:
  HCPCS_DB=<path>   Default database path (dir created automatically).
  Default: ~/.local/share/hcpcs/results.db`)
}

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(1)
	}

	cmd := os.Args[1]
	rest := os.Args[2:]

	var err error
	switch cmd {
	case "record":
		err = cmdRecord(rest)
	case "list":
		err = cmdList(rest)
	case "show":
		err = cmdShow(rest)
	case "trend":
		err = cmdTrend(rest)
	case "--help", "-h", "help":
		usage()
	default:
		fmt.Fprintf(os.Stderr, "unknown command: %s\n\n", cmd)
		usage()
		os.Exit(1)
	}

	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}
