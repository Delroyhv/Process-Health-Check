package main

// hcpcs_alertengine replaces the curl+jq pipeline in chk_metrics.sh.
//
// Key improvements over the shell implementation:
//   - All Prometheus queries issued in parallel (goroutines), not sequentially.
//   - No jq subprocess per value — pure Go JSON decoding.
//   - No SIGPIPE risk under set -euo pipefail.
//   - Output order matches alert definition file order regardless of completion order.
//
// Output format matches chk_metrics.sh exactly so runchk.sh summary grep works:
//   LEVEL : EventID : Description : condMsg [labelInfo][timeInfo] [all? N probes]

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"flag"
	"fmt"
	"math"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

// AlertDef is one entry from hcpcs_hourly_alerts.json or hcpcs_daily_alerts.json.
type AlertDef struct {
	EventID           string `json:"EventID"`
	Description       string `json:"Description"`
	Query             string `json:"Query"`
	Warning           string `json:"Warning"`
	ErrorCrit         string `json:"Error"`
	Ignore            string `json:"Ignore"`
	Label             string `json:"Label"`
	Exclude           string `json:"Exclude"`
	ConsecutiveProbes string `json:"ConsecutiveProbes"`
	Step              string `json:"Step"`
}

// Prometheus API response shapes.
type promReply struct {
	Status string   `json:"status"`
	Data   promData `json:"data"`
}
type promData struct {
	Result []promSeries `json:"result"`
}
type promSeries struct {
	Metric map[string]string `json:"metric"`
	Value  []interface{}     `json:"value"`  // single query: [ts, "val"]
	Values [][]interface{}   `json:"values"` // range query:  [[ts,"val"],...]
}

// ── Threshold helpers ────────────────────────────────────────────────────────

// parseThreshold splits "< 70 optional comment" → (op, limit, comment).
func parseThreshold(s string) (op, limit, comment string) {
	parts := strings.Fields(strings.TrimSpace(s))
	if len(parts) < 2 {
		return
	}
	op, limit = parts[0], parts[1]
	if len(parts) > 2 {
		comment = strings.Join(parts[2:], " ")
	}
	return
}

// cmpOp evaluates `a op b`.
func cmpOp(a float64, op string, b float64) bool {
	switch op {
	case ">":
		return a > b
	case "<":
		return a < b
	case "==":
		return a == b
	case "!=":
		return a != b
	case ">=":
		return a >= b
	case "<=":
		return a <= b
	}
	return false
}

// checkCriteria returns true if `value op limit` where criteria is "op limit".
func checkCriteria(valueStr, criteria string) bool {
	op, limitStr, _ := parseThreshold(criteria)
	if op == "" {
		return false
	}
	v, e1 := strconv.ParseFloat(valueStr, 64)
	l, e2 := strconv.ParseFloat(limitStr, 64)
	if e1 != nil || e2 != nil {
		return false
	}
	return cmpOp(v, op, l)
}

// classify returns the severity level and the condition message for one value.
// level is one of: ERROR, WARNING, INFO, TELEMETRY, IGNORE.
// condMsg mirrors gsc_compare_value output: "value op limit" (e.g. "88 > 70").
func classify(valueStr, warnCrit, errCrit, ignoreCrit string) (level, condMsg string) {
	// Ignore criteria check
	if ignoreCrit != "" {
		op, limitStr, comment := parseThreshold(ignoreCrit)
		if op != "" && checkCriteria(valueStr, ignoreCrit) {
			_ = limitStr
			return "IGNORE", "IGNORE: " + valueStr + " " + comment
		}
	}
	// Negative values are silently skipped (same as shell)
	if strings.HasPrefix(valueStr, "-") {
		return "IGNORE", ""
	}
	// No thresholds → TELEMETRY (record min/max/avg, no alert)
	if warnCrit == "" && errCrit == "" {
		return "TELEMETRY", valueStr
	}
	// ERROR takes priority over WARNING
	if errCrit != "" && checkCriteria(valueStr, errCrit) {
		op, limitStr, _ := parseThreshold(errCrit)
		return "ERROR", fmt.Sprintf("%s %s %s", valueStr, op, limitStr)
	}
	if warnCrit != "" && checkCriteria(valueStr, warnCrit) {
		op, limitStr, _ := parseThreshold(warnCrit)
		return "WARNING", fmt.Sprintf("%s %s %s", valueStr, op, limitStr)
	}
	return "INFO", valueStr
}

// ── Prometheus helpers ───────────────────────────────────────────────────────

func newClient() *http.Client {
	return &http.Client{
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{InsecureSkipVerify: true}, //nolint:gosec
		},
	}
}

func postForm(client *http.Client, endpoint string, vals url.Values, timeout time.Duration) (*promReply, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, strings.NewReader(vals.Encode()))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var pr promReply
	if err := json.NewDecoder(resp.Body).Decode(&pr); err != nil {
		return nil, err
	}
	return &pr, nil
}

func queryInstant(client *http.Client, baseURL, q, t string) (*promReply, error) {
	vals := url.Values{"query": {q}}
	if t != "" {
		vals.Set("time", t)
	}
	return postForm(client, baseURL+"/api/v1/query", vals, 30*time.Second)
}

func queryRange(client *http.Client, baseURL, q string, start, end time.Time, step int) (*promReply, error) {
	vals := url.Values{
		"query": {q},
		"start": {start.UTC().Format(time.RFC3339Nano)},
		"end":   {end.UTC().Format(time.RFC3339Nano)},
		"step":  {fmt.Sprintf("%ds", step)},
	}
	return postForm(client, baseURL+"/api/v1/query_range", vals, 60*time.Second)
}

// probeOldest checks reachability via the tsdb oldest-timestamp metric.
func probeOldest(client *http.Client, baseURL string) bool {
	pr, err := queryInstant(client, baseURL, "prometheus_tsdb_lowest_timestamp_seconds", "")
	return err == nil && pr != nil && pr.Status == "success"
}

// ── Value helpers ────────────────────────────────────────────────────────────

func toFloat(v interface{}) float64 {
	switch x := v.(type) {
	case float64:
		return x
	case json.Number:
		f, _ := x.Float64()
		return f
	case string:
		f, _ := strconv.ParseFloat(x, 64)
		return f
	}
	return 0
}

func valStr(v interface{}) string {
	return strings.Trim(fmt.Sprintf("%v", v), `"`)
}

func fmtNum(f float64) string {
	if f == math.Trunc(f) {
		return fmt.Sprintf("%.0f", f)
	}
	return fmt.Sprintf("%.2f", math.Round(f*100)/100)
}

func epochToDate(epoch float64) string {
	return time.Unix(int64(epoch), 0).UTC().Format("2006-Jan-02")
}

// ── Core processing ──────────────────────────────────────────────────────────

// processAlert runs one alert definition against Prometheus and returns log lines.
func processAlert(def AlertDef, client *http.Client, baseURL string,
	start, end time.Time, probesNum, probesInterval int, rangeMode bool, thresholdStr string) []string {

	// Variable substitution in query string
	q := strings.ReplaceAll(def.Query, "%PROBESTEP", fmt.Sprintf("%ds", probesInterval))
	q = strings.ReplaceAll(q, "%THRESHOLD", thresholdStr)

	// Per-alert step (overrides global interval for range queries)
	step := probesInterval
	if def.Step != "" {
		if s, err := strconv.Atoi(def.Step); err == nil {
			step = s
		}
	}

	// Consecutive probe threshold
	consecLimit := 0
	if def.ConsecutiveProbes != "" {
		if n, err := strconv.Atoi(def.ConsecutiveProbes); err == nil {
			consecLimit = n
		}
	}

	// Skip consecutive-type alerts whose Step != global interval
	// (mirrors shell: "only process this query if steps in the json match the global setting")
	if consecLimit > 0 && def.Step != "" && step != probesInterval {
		return nil
	}

	// Issue Prometheus query
	var pr *promReply
	var qErr error
	if rangeMode {
		pr, qErr = queryRange(client, baseURL, q, start, end, step)
	} else {
		pr, qErr = queryInstant(client, baseURL, q, "")
	}

	if qErr != nil {
		return []string{fmt.Sprintf("INTERNAL-ERROR: FAILED QUERY: %s: %s, err=%s", def.Description, q, qErr)}
	}
	if pr == nil || pr.Status != "success" {
		st := ""
		if pr != nil {
			st = pr.Status
		}
		return []string{fmt.Sprintf("INTERNAL-ERROR: FAILED QUERY: %s: %s, status=%s", def.Description, q, st)}
	}

	var outLines []string

	for _, series := range pr.Data.Result {
		// Label fan-out
		labelName := ""
		if def.Label != "" {
			labelName = series.Metric[def.Label]
		}
		// Exclude filter
		if def.Exclude != "" && labelName == def.Exclude {
			continue
		}

		// Build ordered value list
		var valuesRaw [][]interface{}
		if rangeMode {
			valuesRaw = series.Values
		} else if len(series.Value) >= 2 {
			valuesRaw = [][]interface{}{series.Value}
		}
		if len(valuesRaw) == 0 {
			continue
		}

		// Per-level state (reset per series)
		type lvlState struct {
			firstMsg   string
			firstTime  float64
			firstValue string
			count      int
		}
		levelMap := map[string]*lvlState{}

		// TELEMETRY accumulator
		var telVals []float64
		tsMin := toFloat(valuesRaw[0][0])
		tsMax := tsMin

		// Consecutive accumulator
		consecCount := 0
		var consecMsg, consecLevel string

		for _, vraw := range valuesRaw {
			if len(vraw) < 2 {
				continue
			}
			ts := toFloat(vraw[0])
			vStr := valStr(vraw[1])
			if vStr == "" || vStr == "NaN" {
				continue
			}
			if ts > tsMax {
				tsMax = ts
			}
			if ts < tsMin {
				tsMin = ts
			}

			lvl, condMsg := classify(vStr, def.Warning, def.ErrorCrit, def.Ignore)
			if lvl == "IGNORE" {
				continue
			}
			if lvl == "TELEMETRY" {
				if v, err := strconv.ParseFloat(vStr, 64); err == nil {
					telVals = append(telVals, v)
				}
				continue
			}

			if consecLimit > 0 && rangeMode {
				// Consecutive mode: count unbroken runs of matching probes
				if lvl != "INFO" {
					consecCount++
					consecMsg = condMsg
					consecLevel = lvl
				} else if consecCount >= consecLimit {
					break // already have enough; stop scanning
				} else {
					consecCount = 0 // reset on non-matching probe
				}
				continue
			}

			// Normal mode: first occurrence of each level wins
			if _, exists := levelMap[lvl]; !exists {
				levelMap[lvl] = &lvlState{
					firstMsg:   condMsg,
					firstTime:  ts,
					firstValue: vStr,
				}
			}
			levelMap[lvl].count++
		}

		// ── Emit consecutive alert ──────────────────────────────────────
		if consecLimit > 0 && rangeMode && consecCount >= consecLimit {
			msg := fmt.Sprintf("%s - Consecutive %d probes, %d seconds each",
				consecMsg, consecCount, probesInterval)
			labelInfo := ""
			if labelName != "" {
				labelInfo = fmt.Sprintf(": [%s=%s]", def.Label, labelName)
			}
			all := ""
			if consecCount == probesNum {
				all = "all "
			}
			outLines = append(outLines, fmt.Sprintf("%s : %s : %s : %s %s [%s%d probes]",
				consecLevel, def.EventID, def.Description, msg, labelInfo, all, consecCount))
			continue
		}

		// ── Emit TELEMETRY (min/max/avg over all probes) ─────────────────
		if len(telVals) > 0 {
			sum, minV, maxV := telVals[0], telVals[0], telVals[0]
			for _, v := range telVals[1:] {
				sum += v
				if v < minV {
					minV = v
				}
				if v > maxV {
					maxV = v
				}
			}
			avg := sum / float64(len(telVals))
			timeInfo := ""
			if rangeMode {
				timeInfo = fmt.Sprintf(" [%s - %s]", epochToDate(tsMin), epochToDate(tsMax))
			}
			all := ""
			if len(telVals) == probesNum {
				all = "all "
			}
			msg := fmt.Sprintf("Avg: %s, Max: %s, Min: %s", fmtNum(avg), fmtNum(maxV), fmtNum(minV))
			outLines = append(outLines, fmt.Sprintf("TELEMETRY : %s : %s : %s%s [%s%d probes]",
				def.EventID, def.Description, msg, timeInfo, all, len(telVals)))
		}

		// ── Emit WARNING/ERROR in priority order ─────────────────────────
		for _, lvl := range []string{"ERROR", "WARNING"} {
			st, ok := levelMap[lvl]
			if !ok {
				continue
			}
			labelInfo := ""
			if labelName != "" {
				labelInfo = fmt.Sprintf(": [%s=%s]=%s", def.Label, labelName, st.firstValue)
			}
			timeInfo := ""
			if rangeMode {
				timeInfo = fmt.Sprintf(" [%s]", epochToDate(st.firstTime))
			}
			all := ""
			if st.count == probesNum {
				all = "all "
			}
			// Format mirrors shell: "LEVEL : ID : Desc : condMsg labelInfo timeInfo [all? N probes]"
			outLines = append(outLines, fmt.Sprintf("%s : %s : %s : %s %s%s [%s%d probes]",
				lvl, def.EventID, def.Description, st.firstMsg, labelInfo, timeInfo, all, st.count))
		}
	}

	return outLines
}

// ── main ─────────────────────────────────────────────────────────────────────

func main() {
	host      := flag.String("host", "", "Prometheus host/IP (required)")
	port      := flag.String("port", "9191", "Prometheus port")
	proto     := flag.String("proto", "https", "http or https (auto-switches on failure)")
	jsonFile  := flag.String("json", "", "Alert definitions JSON file (required)")
	outputF   := flag.String("output", "", "Output log file (required)")
	probes    := flag.Int("probes", 24, "Number of range-query probes")
	interval  := flag.Int("interval", 300, "Probe interval in seconds")
	dateStr   := flag.String("date", "", "End time RFC3339 (default: now)")
	threshold := flag.String("threshold", "1000000000", "Value for %%THRESHOLD substitution in queries")
	noRange   := flag.Bool("no-range", false, "Single-query mode (disables range queries; mirrors -b flag)")
	flag.Usage = func() {
		fmt.Fprintf(os.Stderr, "Usage: %s --host <host> --json <file> --output <file> [options]\n", os.Args[0])
		flag.PrintDefaults()
	}
	flag.Parse()

	if *host == "" || *outputF == "" || *jsonFile == "" {
		flag.Usage()
		os.Exit(1)
	}

	// Load alert definitions
	jsonData, err := os.ReadFile(*jsonFile)
	if err != nil {
		fmt.Fprintf(os.Stderr, "ERROR: cannot read %s: %v\n", *jsonFile, err)
		os.Exit(1)
	}
	var defs []AlertDef
	if err := json.Unmarshal(jsonData, &defs); err != nil {
		fmt.Fprintf(os.Stderr, "ERROR: cannot parse JSON: %v\n", err)
		os.Exit(1)
	}

	// Time range
	var endTime time.Time
	if *dateStr != "" {
		// Try RFC3339Nano first, then a few common variants
		for _, layout := range []string{time.RFC3339Nano, "2006-01-02T15:04:05.999Z", time.RFC3339} {
			if t, e := time.Parse(layout, *dateStr); e == nil {
				endTime = t.UTC()
				break
			}
		}
		if endTime.IsZero() {
			fmt.Fprintf(os.Stderr, "ERROR: cannot parse date %q\n", *dateStr)
			os.Exit(1)
		}
	} else {
		endTime = time.Now().UTC()
	}
	startTime := endTime.Add(-time.Duration(*probes-1) * time.Duration(*interval) * time.Second)
	rangeMode := !*noRange

	client := newClient()

	// Protocol probe + auto-switch (mirrors getOldestMetricTimestamp logic)
	activeProto := *proto
	baseURL := fmt.Sprintf("%s://%s:%s", activeProto, *host, *port)
	if !probeOldest(client, baseURL) {
		if activeProto == "https" {
			activeProto = "http"
		} else {
			activeProto = "https"
		}
		baseURL = fmt.Sprintf("%s://%s:%s", activeProto, *host, *port)
		fmt.Fprintf(os.Stderr, "[INFO ] hcpcs_alertengine: auto-switched to %s\n", activeProto)
		if !probeOldest(client, baseURL) {
			fmt.Fprintf(os.Stderr, "[ERROR] hcpcs_alertengine: Prometheus at %s is not reachable\n", baseURL)
			if f, e := os.Create(*outputF); e == nil {
				fmt.Fprintf(f, "ERROR: Prometheus at %s is not reachable - skipping all metric queries\n", baseURL)
				f.Close()
			}
			os.Exit(0)
		}
	}

	fmt.Fprintf(os.Stderr, "[INFO ] hcpcs_alertengine: %s, %d defs, %d probes × %ds\n",
		baseURL, len(defs), *probes, *interval)

	// Fire all queries in parallel; write output in definition order.
	results := make([][]string, len(defs))
	var wg sync.WaitGroup
	for i, def := range defs {
		wg.Add(1)
		go func(idx int, d AlertDef) {
			defer wg.Done()
			results[idx] = processAlert(d, client, baseURL, startTime, endTime,
				*probes, *interval, rangeMode, *threshold)
		}(i, def)
	}
	wg.Wait()

	// Write output file
	outFile, err := os.Create(*outputF)
	if err != nil {
		fmt.Fprintf(os.Stderr, "ERROR: cannot create %s: %v\n", *outputF, err)
		os.Exit(1)
	}
	defer outFile.Close()

	count := 0
	for _, lines := range results {
		for _, line := range lines {
			fmt.Fprintln(outFile, line)
			count++
		}
	}
	fmt.Fprintf(os.Stderr, "[INFO ] hcpcs_alertengine: wrote %s (%d messages)\n", *outputF, count)
}
