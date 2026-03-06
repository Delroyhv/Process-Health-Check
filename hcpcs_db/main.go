package main

// hcpcs_db — stores and queries health-check run results in a SQLite database.
//
// Commands:
//   record  [flags]    Scan health_report*.log in cwd and insert a run record.
//   list    [flags]    Show recent runs as an aligned table.
//   show    <id>       Show all issues for one run.
//   trend   <sr>       Show per-run severity counts for one SR over time.
//   serve   [flags]    MCP stdio server (JSON-RPC 2.0 over stdin/stdout).
//
// Environment:
//   HCPCS_DB=<path>   Default database path (used when --db is not specified).
//                     The file and its parent directory are created if absent.
//
// Default path when HCPCS_DB is unset: ~/.local/share/hcpcs/results.db

import (
	"bufio"
	"bytes"
	"database/sql"
	"encoding/json"
	"flag"
	"fmt"
	"io"
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

// ── MCP types ────────────────────────────────────────────────────────────────

type mcpRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      interface{}     `json:"id"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type mcpResponse struct {
	JSONRPC string      `json:"jsonrpc"`
	ID      interface{} `json:"id"`
	Result  interface{} `json:"result,omitempty"`
	Error   *mcpError   `json:"error,omitempty"`
}

type mcpError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

func mcpErr(id interface{}, code int, msg string) mcpResponse {
	return mcpResponse{JSONRPC: "2.0", ID: id, Error: &mcpError{Code: code, Message: msg}}
}

func mcpOK(id interface{}, result interface{}) mcpResponse {
	return mcpResponse{JSONRPC: "2.0", ID: id, Result: result}
}

func mcpText(id interface{}, text string) mcpResponse {
	return mcpOK(id, map[string]interface{}{
		"content": []map[string]interface{}{{"type": "text", "text": text}},
	})
}

func mcpTextErr(id interface{}, text string) mcpResponse {
	return mcpOK(id, map[string]interface{}{
		"content": []map[string]interface{}{{"type": "text", "text": text}},
		"isError": true,
	})
}

// mcpToolDefs is the tool list returned by tools/list.
var mcpToolDefs = []map[string]interface{}{
	{
		"name":        "list_runs",
		"description": "List recent health check runs from the results database",
		"inputSchema": map[string]interface{}{
			"type": "object",
			"properties": map[string]interface{}{
				"limit": map[string]interface{}{
					"type":        "integer",
					"description": "Maximum number of runs to return (default 20)",
				},
				"sr": map[string]interface{}{
					"type":        "string",
					"description": "Filter by SR number (8 digits, e.g. 05448336)",
				},
			},
		},
	},
	{
		"name":        "show_run",
		"description": "Show all recorded issues for a specific health check run",
		"inputSchema": map[string]interface{}{
			"type": "object",
			"properties": map[string]interface{}{
				"id": map[string]interface{}{
					"type":        "integer",
					"description": "Run ID (from list_runs output)",
				},
			},
			"required": []string{"id"},
		},
	},
	{
		"name":        "trend_sr",
		"description": "Show severity trend over time for one SR number",
		"inputSchema": map[string]interface{}{
			"type": "object",
			"properties": map[string]interface{}{
				"sr": map[string]interface{}{
					"type":        "string",
					"description": "SR number (8 digits, e.g. 05448336)",
				},
			},
			"required": []string{"sr"},
		},
	},
	{
		"name":        "record_run",
		"description": "Scan a health check run directory and store results in the database",
		"inputSchema": map[string]interface{}{
			"type": "object",
			"properties": map[string]interface{}{
				"dir": map[string]interface{}{
					"type":        "string",
					"description": "Directory containing health_report*.log files (default: current directory)",
				},
				"elapsed": map[string]interface{}{
					"type":        "integer",
					"description": "Elapsed seconds for the run",
				},
				"customer": map[string]interface{}{
					"type":        "string",
					"description": "Customer name",
				},
				"sr": map[string]interface{}{
					"type":        "string",
					"description": "SR number (auto-inferred from path if omitted)",
				},
			},
		},
	},
}

// ── Print helpers (write formatted output to any io.Writer) ──────────────────

func printList(w io.Writer, db *sql.DB, limit int, sr string) error {
	q := `SELECT id, ts, sr_number, customer, cs_version, node_count, elapsed_sec,
	             critical_count, danger_count, error_count, warning_count, action_count, issues_total
	      FROM runs`
	var qargs []interface{}
	if sr != "" {
		q += " WHERE sr_number = ?"
		qargs = append(qargs, sr)
	}
	q += " ORDER BY ts DESC LIMIT ?"
	qargs = append(qargs, limit)

	rows, err := db.Query(q, qargs...)
	if err != nil {
		return err
	}
	defer rows.Close()

	type row struct {
		id, nodes, elapsed, crit, dang, err_, warn, act, total int
		ts, sr, customer, ver                                   string
	}
	var data []row
	for rows.Next() {
		var r row
		if e := rows.Scan(&r.id, &r.ts, &r.sr, &r.customer, &r.ver, &r.nodes, &r.elapsed,
			&r.crit, &r.dang, &r.err_, &r.warn, &r.act, &r.total); e != nil {
			return e
		}
		if len(r.ts) > 19 {
			r.ts = r.ts[:19]
		}
		data = append(data, r)
	}

	if len(data) == 0 {
		fmt.Fprintln(w, "No runs recorded yet.")
		return nil
	}

	// Reverse so oldest-first (makes trend reading easier)
	for i, j := 0, len(data)-1; i < j; i, j = i+1, j-1 {
		data[i], data[j] = data[j], data[i]
	}

	fmt.Fprintf(w, "%-4s  %-19s  %-10s  %-10s  %-8s  %-5s  %-7s  %-4s  %-4s  %-4s  %-5s  %-4s\n",
		"ID", "Timestamp", "SR", "Customer", "Version", "Nodes", "Elapsed", "CRIT", "DANG", "ERR", "WARN", "ACT")
	fmt.Fprintln(w, strings.Repeat("-", 103))
	for _, r := range data {
		fmt.Fprintf(w, "%-4d  %-19s  %-10s  %-10s  %-8s  %-5d  %-7s  %-4d  %-4d  %-4d  %-5d  %-4d\n",
			r.id, r.ts, r.sr, r.customer, r.ver, r.nodes,
			fmt.Sprintf("%ds", r.elapsed),
			r.crit, r.dang, r.err_, r.warn, r.act)
	}
	fmt.Fprintf(w, "\n%d run(s) shown. Use 'hcpcs_db show <id>' for issue details.\n", len(data))
	return nil
}

func printShow(w io.Writer, db *sql.DB, id int) error {
	var ts, runDir, sr, customer, ver string
	var nodes, elapsed, crit, dang, errC, warn, act, total int
	err := db.QueryRow(`SELECT ts, run_dir, sr_number, customer, cs_version, node_count, elapsed_sec,
		critical_count, danger_count, error_count, warning_count, action_count, issues_total
		FROM runs WHERE id=?`, id).
		Scan(&ts, &runDir, &sr, &customer, &ver, &nodes, &elapsed,
			&crit, &dang, &errC, &warn, &act, &total)
	if err == sql.ErrNoRows {
		return fmt.Errorf("run #%d not found", id)
	}
	if err != nil {
		return err
	}

	fmt.Fprintf(w, "Run #%d  |  %s\n", id, ts)
	fmt.Fprintf(w, "  SR: %-12s  Customer: %-12s  Version: %s  Nodes: %d  Elapsed: %ds\n",
		sr, customer, ver, nodes, elapsed)
	fmt.Fprintf(w, "  Dir: %s\n", runDir)
	fmt.Fprintf(w, "  Issues: %d total  (CRIT:%d  DANG:%d  ERR:%d  WARN:%d  ACT:%d)\n\n",
		total, crit, dang, errC, warn, act)

	if total == 0 {
		fmt.Fprintln(w, "  No issues recorded.")
		return nil
	}

	rows, err := db.Query(`
		SELECT severity, source, message FROM issues
		WHERE run_id=?
		ORDER BY
		  CASE severity WHEN 'CRITICAL' THEN 1 WHEN 'DANGER' THEN 2
		                WHEN 'ERROR' THEN 3 WHEN 'WARNING' THEN 4
		                WHEN 'ACTION' THEN 5 ELSE 6 END,
		  source, id`,
		id)
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
			fmt.Fprintf(w, "  ── %s ──\n", sev)
			curSev = sev
		}
		fmt.Fprintf(w, "    [%-8s] %s\n", source, msg)
	}
	return nil
}

func printTrend(w io.Writer, db *sql.DB, sr string) error {
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
		fmt.Fprintf(w, "No runs found for SR %s.\n", sr)
		return nil
	}

	fmt.Fprintf(w, "Trend for SR %s (%d run(s)):\n\n", sr, len(data))
	fmt.Fprintf(w, "%-4s  %-19s  %-7s  %-5s  %-4s  %-4s  %-4s  %-5s  %-4s\n",
		"ID", "Timestamp", "Elapsed", "Total", "CRIT", "DANG", "ERR", "WARN", "ACT")
	fmt.Fprintln(w, strings.Repeat("-", 72))

	for i, r := range data {
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
		fmt.Fprintf(w, "%-4d  %-19s  %-7s  %s%-4d  %-4d  %-4d  %-4d  %-5d  %-4d\n",
			r.id, r.ts, fmt.Sprintf("%ds", r.elapsed),
			arrow, r.total, r.crit, r.dang, r.errC, r.warn, r.act)
	}
	return nil
}

// ── Record helper ─────────────────────────────────────────────────────────────

// doRecord scans a directory and inserts one run + issues in the DB.
// Returns a human-readable summary string on success.
func doRecord(db *sql.DB, absDir, sr, customer string, elapsed int) (string, error) {
	parsedVersion, nodeCount := parseClusterInfo(absDir)
	if sr == "" {
		sr = inferSR(absDir)
	}

	issues, err := scanIssues(absDir)
	if err != nil {
		return "", fmt.Errorf("scan issues: %w", err)
	}

	counts := map[string]int{"CRITICAL": 0, "DANGER": 0, "ERROR": 0, "WARNING": 0, "ACTION": 0}
	for _, iss := range issues {
		counts[iss.severity]++
	}
	total := len(issues)

	tx, err := db.Begin()
	if err != nil {
		return "", err
	}
	defer tx.Rollback()

	ts := time.Now().UTC().Format(time.RFC3339)
	res, err := tx.Exec(`INSERT INTO runs
		(ts, run_dir, sr_number, customer, cs_version, node_count, elapsed_sec,
		 critical_count, danger_count, error_count, warning_count, action_count, issues_total)
		VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)`,
		ts, absDir, sr, customer, parsedVersion, nodeCount, elapsed,
		counts["CRITICAL"], counts["DANGER"], counts["ERROR"],
		counts["WARNING"], counts["ACTION"], total)
	if err != nil {
		return "", fmt.Errorf("insert run: %w", err)
	}
	runID, _ := res.LastInsertId()

	stmt, err := tx.Prepare(`INSERT INTO issues (run_id, severity, source, message) VALUES (?,?,?,?)`)
	if err != nil {
		return "", err
	}
	for _, iss := range issues {
		if _, err := stmt.Exec(runID, iss.severity, iss.source, iss.message); err != nil {
			return "", err
		}
	}
	stmt.Close()

	if err := tx.Commit(); err != nil {
		return "", err
	}

	return fmt.Sprintf("Recorded run #%d — %d issues (CRIT:%d DANG:%d ERR:%d WARN:%d ACT:%d)",
		runID, total, counts["CRITICAL"], counts["DANGER"], counts["ERROR"],
		counts["WARNING"], counts["ACTION"]), nil
}

// ── CLI Commands ──────────────────────────────────────────────────────────────

func cmdRecord(args []string) error {
	fs := flag.NewFlagSet("record", flag.ExitOnError)
	dbPath   := fs.String("db", defaultDBPath(), "Database path")
	dir      := fs.String("dir", ".", "Directory containing health_report*.log files")
	sr       := fs.String("sr", "", "SR number (auto-inferred from path if omitted)")
	customer := fs.String("customer", "", "Customer name")
	elapsed  := fs.Int("elapsed", 0, "Elapsed seconds (from runchk.sh)")
	fs.Parse(args)

	absDir, err := filepath.Abs(*dir)
	if err != nil {
		return err
	}

	db, err := openDB(*dbPath)
	if err != nil {
		return err
	}
	defer db.Close()

	summary, err := doRecord(db, absDir, *sr, *customer, *elapsed)
	if err != nil {
		return err
	}
	fmt.Fprintf(os.Stderr, "[INFO ] hcpcs_db: %s → %s\n", summary, *dbPath)
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

	return printList(os.Stdout, db, *limit, *sr)
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

	return printShow(os.Stdout, db, runID)
}

func cmdTrend(args []string) error {
	fs := flag.NewFlagSet("trend", flag.ExitOnError)
	dbPath := fs.String("db", defaultDBPath(), "Database path")
	fs.Parse(args)

	if fs.NArg() < 1 {
		return fmt.Errorf("usage: hcpcs_db trend <sr_number>")
	}

	db, err := openDB(*dbPath)
	if err != nil {
		return err
	}
	defer db.Close()

	return printTrend(os.Stdout, db, fs.Arg(0))
}

// ── MCP serve ─────────────────────────────────────────────────────────────────

// dispatchMCP handles one JSON-RPC 2.0 request and returns the response.
func dispatchMCP(req mcpRequest, dbPath string) mcpResponse {
	switch req.Method {
	case "initialize":
		return mcpOK(req.ID, map[string]interface{}{
			"protocolVersion": "2024-11-05",
			"capabilities":    map[string]interface{}{"tools": map[string]interface{}{}},
			"serverInfo":      map[string]interface{}{"name": "hcpcs_db", "version": "1.0"},
		})

	case "tools/list":
		return mcpOK(req.ID, map[string]interface{}{"tools": mcpToolDefs})

	case "tools/call":
		var p struct {
			Name      string          `json:"name"`
			Arguments json.RawMessage `json:"arguments"`
		}
		if err := json.Unmarshal(req.Params, &p); err != nil {
			return mcpErr(req.ID, -32600, "invalid params: "+err.Error())
		}

		db, err := openDB(dbPath)
		if err != nil {
			return mcpTextErr(req.ID, "Error opening database: "+err.Error())
		}
		defer db.Close()

		var buf strings.Builder
		switch p.Name {
		case "list_runs":
			var a struct {
				Limit int    `json:"limit"`
				SR    string `json:"sr"`
			}
			a.Limit = 20
			if len(p.Arguments) > 0 {
				json.Unmarshal(p.Arguments, &a) //nolint:errcheck
			}
			if err := printList(&buf, db, a.Limit, a.SR); err != nil {
				return mcpTextErr(req.ID, "Error: "+err.Error())
			}

		case "show_run":
			var a struct {
				ID int `json:"id"`
			}
			if err := json.Unmarshal(p.Arguments, &a); err != nil || a.ID == 0 {
				return mcpTextErr(req.ID, "Error: 'id' (integer) is required")
			}
			if err := printShow(&buf, db, a.ID); err != nil {
				return mcpTextErr(req.ID, "Error: "+err.Error())
			}

		case "trend_sr":
			var a struct {
				SR string `json:"sr"`
			}
			if err := json.Unmarshal(p.Arguments, &a); err != nil || a.SR == "" {
				return mcpTextErr(req.ID, "Error: 'sr' (string) is required")
			}
			if err := printTrend(&buf, db, a.SR); err != nil {
				return mcpTextErr(req.ID, "Error: "+err.Error())
			}

		case "record_run":
			var a struct {
				Dir      string `json:"dir"`
				Elapsed  int    `json:"elapsed"`
				Customer string `json:"customer"`
				SR       string `json:"sr"`
			}
			a.Dir = "."
			if len(p.Arguments) > 0 {
				json.Unmarshal(p.Arguments, &a) //nolint:errcheck
			}
			absDir, err := filepath.Abs(a.Dir)
			if err != nil {
				return mcpTextErr(req.ID, "Error: "+err.Error())
			}
			summary, err := doRecord(db, absDir, a.SR, a.Customer, a.Elapsed)
			if err != nil {
				return mcpTextErr(req.ID, "Error: "+err.Error())
			}
			fmt.Fprintln(&buf, summary)

		default:
			return mcpErr(req.ID, -32602, "unknown tool: "+p.Name)
		}
		return mcpText(req.ID, buf.String())

	default:
		return mcpErr(req.ID, -32601, "method not found: "+req.Method)
	}
}

func cmdServe(args []string) error {
	fs := flag.NewFlagSet("serve", flag.ExitOnError)
	dbPath := fs.String("db", defaultDBPath(), "Database path")
	fs.Parse(args)

	scanner := bufio.NewScanner(os.Stdin)
	enc := json.NewEncoder(os.Stdout)

	for scanner.Scan() {
		line := bytes.TrimSpace(scanner.Bytes())
		if len(line) == 0 {
			continue
		}

		var req mcpRequest
		if err := json.Unmarshal(line, &req); err != nil {
			// Malformed JSON — send parse error with null id
			enc.Encode(mcpErr(nil, -32700, "parse error: "+err.Error())) //nolint:errcheck
			continue
		}
		if req.ID == nil {
			// Notification (no id field) — silently ignore
			continue
		}

		enc.Encode(dispatchMCP(req, *dbPath)) //nolint:errcheck
	}
	return scanner.Err()
}

// ── main ─────────────────────────────────────────────────────────────────────

func usage() {
	fmt.Fprintln(os.Stderr, `hcpcs_db — Health-check results database

Commands:
  record  [--db PATH] [--dir DIR] [--sr SR] [--customer NAME] [--elapsed N]
          Scan health_report*.log in DIR (default: cwd) and insert a run record.

  list    [--db PATH] [--limit N] [--sr SR]
          Show recent runs as an aligned table.

  show    [--db PATH] <run_id>
          Show all issues for one run.

  trend   [--db PATH] <sr_number>
          Show per-run severity counts for one SR over time.

  serve   [--db PATH]
          MCP stdio server (JSON-RPC 2.0). Exposes list_runs, show_run,
          trend_sr, record_run as MCP tools.

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
	case "serve":
		err = cmdServe(rest)
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
