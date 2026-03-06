package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// Alert from aspen alert/list endpoint
type Alert struct {
	Timestamp int64  `json:"timestamp"` // milliseconds
	Category  string `json:"category"`
	Descr     string `json:"description"`
}

// Event from aspen system/info endpoint
type Event struct {
	Severity  string `json:"severity"`
	Subject   string `json:"subject"`
	Message   string `json:"message"`
	Subsystem string `json:"subsystem"`
	Timestamp int64  `json:"timestamp"` // milliseconds
}

type EventsWrapper struct {
	Events []Event `json:"events"`
}

const (
	alertsShort = "get-config_aspen_alert-list.out"
	eventsShort = "get-config_aspen_system-info.out"
)

// findFile walks dir looking for a file whose base name contains target as a substring.
// Matches e.g. "1155_09_get-config_aspen_alert-list.out" when target is "get-config_aspen_alert-list.out".
func findFile(dir, target string) string {
	var found string
	_ = filepath.WalkDir(dir, func(path string, d os.DirEntry, err error) error {
		if err != nil || found != "" {
			return nil
		}
		if !d.IsDir() && strings.Contains(d.Name(), target) {
			found = path
			return filepath.SkipAll
		}
		return nil
	})
	return found
}

func readNoComment(path string) ([]byte, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	if len(data) > 0 && data[0] == '#' {
		idx := bytes.IndexByte(data, '\n')
		if idx < 0 {
			return nil, nil
		}
		return data[idx+1:], nil
	}
	return data, nil
}

func main() {
	dir        := flag.String("dir", ".", "directory to search for alert/event JSON files")
	alertsFile := flag.String("alerts", "", "alerts JSON file (overrides --dir discovery)")
	eventsFile := flag.String("events", "", "events JSON file (overrides --dir discovery)")
	outputFile := flag.String("output", "", "output log file (required)")
	days       := flag.Int("days", 30, "filter to last N days")
	flag.Usage = func() {
		fmt.Fprintf(os.Stderr,
			"Usage: %s --output <log> [--dir <dir>] [--alerts <json>] [--events <json>] [--days N]\n",
			os.Args[0])
	}
	flag.Parse()

	if *outputFile == "" {
		flag.Usage()
		os.Exit(1)
	}

	// File discovery via --dir when explicit paths not given
	if *alertsFile == "" {
		*alertsFile = findFile(*dir, alertsShort)
	}
	if *eventsFile == "" {
		*eventsFile = findFile(*dir, eventsShort)
	}

	cutoffMs := time.Now().AddDate(0, 0, -*days).UnixMilli()

	out, err := os.Create(*outputFile)
	if err != nil {
		fmt.Fprintln(os.Stderr, "error creating output:", err)
		os.Exit(1)
	}
	defer out.Close()

	// ── Alerts ───────────────────────────────────────────────────────────────
	if *alertsFile != "" {
		data, err := readNoComment(*alertsFile)
		if err != nil {
			fmt.Fprintf(os.Stderr, "WARNING: cannot read alerts file: %v\n", err)
		} else if len(data) > 0 {
			var alerts []Alert
			if err := json.Unmarshal(data, &alerts); err != nil {
				fmt.Fprintf(os.Stderr, "WARNING: cannot parse alerts JSON: %v\n", err)
			} else {
				var recent []Alert
				for _, a := range alerts {
					if a.Timestamp > cutoffMs {
						recent = append(recent, a)
					}
				}
				if len(recent) == 0 {
					fmt.Fprintf(out, "No system alerts in the past %d days\n", *days)
				} else {
					fmt.Fprintf(out, "WARNING: %d alerts in the past %d days:\n", len(recent), *days)
					for _, a := range recent {
						ts := time.UnixMilli(a.Timestamp).UTC().Format("2006-Jan-02")
						fmt.Fprintf(out, "%s %s %s\n", ts, a.Category, a.Descr)
					}
				}
			}
		}
	}

	// ── Events ───────────────────────────────────────────────────────────────
	if *eventsFile != "" {
		data, err := readNoComment(*eventsFile)
		if err != nil {
			fmt.Fprintf(os.Stderr, "WARNING: cannot read events file: %v\n", err)
		} else if len(data) > 0 {
			var wrapper EventsWrapper
			if err := json.Unmarshal(data, &wrapper); err != nil {
				fmt.Fprintf(os.Stderr, "WARNING: cannot parse events JSON: %v\n", err)
			} else {
				// Keep only non-INFO events within cutoff; dedup by subject (most recent wins)
				bySubject := map[string]Event{}
				for _, e := range wrapper.Events {
					if strings.EqualFold(e.Severity, "INFO") {
						continue
					}
					if e.Timestamp <= cutoffMs {
						continue
					}
					if existing, ok := bySubject[e.Subject]; !ok || e.Timestamp > existing.Timestamp {
						bySubject[e.Subject] = e
					}
				}
				if len(bySubject) == 0 {
					fmt.Fprintf(out, "No system events in the past %d days\n", *days)
				} else {
					subjects := make([]string, 0, len(bySubject))
					for s := range bySubject {
						subjects = append(subjects, s)
					}
					sort.Strings(subjects)
					fmt.Fprintf(out, "WARNING: %d types of events in the past %d days:\n",
						len(subjects), *days)
					for _, subj := range subjects {
						e := bySubject[subj]
						ts := time.UnixMilli(e.Timestamp).UTC().Format("2006-Jan-02")
						fmt.Fprintf(out, "%s %s %s %s %s\n",
							ts, e.Severity, e.Subsystem, e.Subject, e.Message)
					}
				}
			}
		}
	}

	fmt.Fprintf(os.Stderr, "[INFO ] chk_alerts: wrote %s\n", *outputFile)
}
