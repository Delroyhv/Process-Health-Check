package main

import (
	"bufio"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

const (
	idealLimit    = 500
	cautiousLimit = 900
)

var (
	ansiRe      = regexp.MustCompile(`\x1b\[[0-9;]*m`)
	logPrefixRe = regexp.MustCompile(`^\[[A-Z ]+\]\s*`)
)

func ceilDiv(a, b int) int {
	if b <= 0 {
		return 0
	}
	return (a + b - 1) / b
}

func max0(n int) int {
	if n < 0 {
		return 0
	}
	return n
}

func statusLabel(copies int) string {
	switch {
	case copies >= 2000:
		return "CRITICAL"
	case copies >= 1500:
		return "DANGER"
	case copies >= 1000:
		return "WARNING"
	case copies >= cautiousLimit:
		return "WARNING"
	default:
		return "OK"
	}
}

// stripLine removes ANSI codes and log-level prefix from a line.
func stripLine(line string) string {
	line = ansiRe.ReplaceAllString(line, "")
	line = logPrefixRe.ReplaceAllString(strings.TrimSpace(line), "")
	return strings.TrimSpace(line)
}

// parsePrefix returns the integer following prefix on a line, if present.
func parsePrefix(line, prefix string) (int, bool) {
	line = stripLine(line)
	if !strings.HasPrefix(line, prefix) {
		return 0, false
	}
	rest := strings.TrimSpace(strings.TrimPrefix(line, prefix))
	fields := strings.Fields(rest)
	if len(fields) == 0 {
		return 0, false
	}
	n, err := strconv.Atoi(fields[0])
	if err != nil {
		return 0, false
	}
	return n, true
}

func scanFile(path, prefix string) (int, bool) {
	f, err := os.Open(path)
	if err != nil {
		return 0, false
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		if n, ok := parsePrefix(sc.Text(), prefix); ok {
			return n, true
		}
	}
	return 0, false
}

func scanGlob(pattern, prefix string) (int, bool) {
	matches, _ := filepath.Glob(pattern)
	for _, m := range matches {
		if n, ok := scanFile(m, prefix); ok {
			return n, true
		}
	}
	return 0, false
}

func addSign(n int) string {
	if n > 0 {
		return fmt.Sprintf("+%d", n)
	}
	return "0"
}

func sep() string {
	return strings.Repeat("-", 64)
}

func main() {
	dir           := flag.String("dir", ".", "directory containing health check log files")
	threshCurrent := flag.Int("threshold-current", 1, "current partition size threshold in GB")
	threshNew     := flag.Int("threshold-new", 1, "proposed new partition size threshold in GB")
	mdgwOverride  := flag.Int("mdgw", 0, "MDGW node count override (use when log reports N/A)")

	flag.Usage = func() {
		fmt.Fprintf(os.Stderr, "Usage: %s [options]\n\nOptions:\n", os.Args[0])
		fmt.Fprintf(os.Stderr, "  --dir PATH              log directory (default: .)\n")
		fmt.Fprintf(os.Stderr, "  --threshold-current N   current partition threshold in GB (default: 1)\n")
		fmt.Fprintf(os.Stderr, "  --threshold-new N       proposed new threshold in GB (default: same as current)\n")
		fmt.Fprintf(os.Stderr, "  --mdgw N                MDGW node count override (use when log reports N/A)\n")
	}
	flag.Parse()

	if *threshCurrent <= 0 {
		*threshCurrent = 1
	}
	if *threshNew < *threshCurrent {
		*threshNew = *threshCurrent
	}

	// ── Locate log files ────────────────────────────────────────────────────
	partLog   := filepath.Join(*dir, "health_report_partition_details.log")
	svcGlob   := filepath.Join(*dir, "health_report_services*.log")
	splitsLog := filepath.Join(*dir, "partition_splits.log")

	uniquePartitions, okP := scanFile(partLog,   "Count of partitions:")
	mdgwNodes,        okM := scanGlob(svcGlob,   "MDGW instances:")
	avgMonthly,       okG := scanFile(splitsLog,  "avg_monthly_growth:")

	if !okP {
		fmt.Fprintln(os.Stderr, "error: 'Count of partitions:' not found in", partLog)
	}
	if !okG {
		fmt.Fprintln(os.Stderr, "error: 'avg_monthly_growth:' not found in", splitsLog)
	}

	// MDGW may be N/A in the log; accept --mdgw override or default to 1 with warning.
	if !okM {
		if *mdgwOverride > 0 {
			mdgwNodes = *mdgwOverride
			fmt.Fprintf(os.Stderr, "warn: 'MDGW instances:' not found or N/A — using --mdgw override: %d\n", mdgwNodes)
		} else {
			fmt.Fprintf(os.Stderr, "warn: 'MDGW instances:' not found or N/A — defaulting to 1 (use --mdgw N to override)\n")
			mdgwNodes = 1
		}
	} else if *mdgwOverride > 0 {
		mdgwNodes = *mdgwOverride
	}

	if !okP || !okG {
		os.Exit(1)
	}
	if mdgwNodes <= 0 {
		mdgwNodes = 1
	}

	// ── Core calculations ────────────────────────────────────────────────────
	clusterPartitions := uniquePartitions * 3
	copiesPerNode     := clusterPartitions / mdgwNodes

	// Effective monthly growth with threshold increase.
	// ceil(avg * current / new) avoids floating point.
	effectiveMonthly := avgMonthly
	if *threshNew > *threshCurrent {
		effectiveMonthly = ceilDiv(avgMonthly * *threshCurrent, *threshNew)
	}

	threshChanged := *threshNew != *threshCurrent

	// 12-month future cluster copies
	futureBase := clusterPartitions + avgMonthly*3*12
	futureNew  := clusterPartitions + effectiveMonthly*3*12

	// Nodes needed (ceiling division)
	niNow := ceilDiv(clusterPartitions, idealLimit)
	ncNow := ceilDiv(clusterPartitions, cautiousLimit)
	ni12b := ceilDiv(futureBase, idealLimit)
	nc12b := ceilDiv(futureBase, cautiousLimit)
	ni12n := ceilDiv(futureNew,  idealLimit)
	nc12n := ceilDiv(futureNew,  cautiousLimit)

	aiNow := max0(niNow - mdgwNodes)
	acNow := max0(ncNow - mdgwNodes)
	ai12b := max0(ni12b - mdgwNodes)
	ac12b := max0(nc12b - mdgwNodes)
	ai12n := max0(ni12n - mdgwNodes)
	ac12n := max0(nc12n - mdgwNodes)

	status := statusLabel(copiesPerNode)

	// ── Output ───────────────────────────────────────────────────────────────
	s := sep()

	fmt.Println("--- Cluster Growth Forecast ---")
	fmt.Println()
	fmt.Println("  Current State")
	fmt.Printf("    Unique partitions       : %7d\n",        uniquePartitions)
	fmt.Printf("    Cluster partitions      : %7d  (x3 replicas)\n", clusterPartitions)
	fmt.Printf("    MDGW nodes              : %7d\n",        mdgwNodes)
	fmt.Printf("    Copies/node (current)   : %7d  [%s]\n",  copiesPerNode, status)
	fmt.Printf("    Partition threshold     : %7d GB\n",     *threshCurrent)
	fmt.Printf("    Avg monthly growth      : %7d splits/month\n", avgMonthly)
	fmt.Println()

	// NOW
	fmt.Println(s)
	fmt.Printf("  Nodes Required TODAY  (%d cluster partitions)\n", clusterPartitions)
	fmt.Println(s)
	fmt.Printf("  %-10s  Copies/node limit  Nodes needed  Nodes to add\n", "Target")
	fmt.Printf("  %-10s  %17d  %12d  %12s\n", "Ideal",    idealLimit,    niNow, addSign(aiNow))
	fmt.Printf("  %-10s  %17d  %12d  %12s\n", "Cautious", cautiousLimit, ncNow, addSign(acNow))
	fmt.Println()

	// 12-month baseline
	fmt.Println(s)
	fmt.Printf("  12-Month Forecast  (no threshold change, %d GB)\n", *threshCurrent)
	fmt.Println(s)
	fmt.Printf("  Monthly copy growth       : %d splits x3 = %d copies/month\n",
		avgMonthly, avgMonthly*3)
	fmt.Printf("  Future cluster partitions : %d\n", futureBase)
	fmt.Printf("  %-10s  Copies/node limit  Nodes needed  Nodes to add\n", "Target")
	fmt.Printf("  %-10s  %17d  %12d  %12s\n", "Ideal",    idealLimit,    ni12b, addSign(ai12b))
	fmt.Printf("  %-10s  %17d  %12d  %12s\n", "Cautious", cautiousLimit, nc12b, addSign(ac12b))
	fmt.Println()

	// 12-month with new threshold
	if threshChanged {
		multiplier := *threshNew / *threshCurrent
		fmt.Println(s)
		fmt.Printf("  12-Month Forecast  (threshold increase %d GB -> %d GB  [x%d])\n",
			*threshCurrent, *threshNew, multiplier)
		fmt.Println(s)
		fmt.Printf("  Effective monthly growth  : %d splits/month  (reduced from %d by x%d threshold)\n",
			effectiveMonthly, avgMonthly, multiplier)
		fmt.Printf("  Monthly copy growth       : %d splits x3 = %d copies/month\n",
			effectiveMonthly, effectiveMonthly*3)
		fmt.Printf("  Future cluster partitions : %d\n", futureNew)
		fmt.Printf("  %-10s  Copies/node limit  Nodes needed  Nodes to add\n", "Target")
		fmt.Printf("  %-10s  %17d  %12d  %12s\n", "Ideal",    idealLimit,    ni12n, addSign(ai12n))
		fmt.Printf("  %-10s  %17d  %12d  %12s\n", "Cautious", cautiousLimit, nc12n, addSign(ac12n))
		fmt.Println()

		// Savings
		fmt.Println(s)
		fmt.Printf("  Savings from %d GB -> %d GB threshold increase (12-month)\n",
			*threshCurrent, *threshNew)
		fmt.Println(s)
		fmt.Printf("  Ideal    : %d -> %d nodes  (saves %d nodes)\n", ni12b, ni12n, ni12b-ni12n)
		fmt.Printf("  Cautious : %d -> %d nodes  (saves %d nodes)\n", nc12b, nc12n, nc12b-nc12n)
		fmt.Println()
	}

	// ACTION lines
	if acNow > 0 {
		fmt.Printf("[ACTION] To reach Cautious threshold today: add %d MDGW nodes (%d -> %d).\n",
			acNow, mdgwNodes, ncNow)
	}
	if threshChanged {
		if ac12b > 0 {
			fmt.Printf("[ACTION] Cautious over 12 months WITHOUT threshold change: add %d nodes (%d -> %d).\n",
				ac12b, mdgwNodes, nc12b)
		}
		if ac12n > 0 {
			fmt.Printf("[ACTION] Cautious over 12 months WITH %d GB threshold: add %d nodes (%d -> %d).\n",
				*threshNew, ac12n, mdgwNodes, nc12n)
		}
		savings := nc12b - nc12n
		if savings > 0 {
			fmt.Printf("[ACTION] Increasing threshold %d GB -> %d GB saves %d nodes at Cautious level over 12 months.\n",
				*threshCurrent, *threshNew, savings)
		}
	} else {
		if ac12b > 0 {
			fmt.Printf("[ACTION] To maintain Cautious threshold over 12 months: add %d MDGW nodes (%d -> %d).\n",
				ac12b, mdgwNodes, nc12b)
		}
	}
}
