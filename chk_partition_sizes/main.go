package main

// chk_partition_sizes — reads clusterPartitionState_Metadata-Coordination_*.json
// files under a directory tree, extracts partitionId/partitionSize/keySpaceId/nodeCount,
// sorts by partitionSize descending, writes a flat file, and emits a WARNING when
// the largest partition size is >= 1.5× the configured split threshold.
//
// Usage:
//   chk_partition_sizes [--dir DIR] [--threshold VALUE] [--output FILE]
//
// CLI flags:
//   --dir DIR         Root directory to search (default: ".")
//   --threshold VALUE Split threshold with unit suffix (e.g. 1Gi, 2G, 512Mi).
//                     If omitted or empty, only the flat file is written.
//   --output FILE     Flat output file path (default: "partition_size_analysis.log")
//
// Output file format (tab-separated, sorted by partitionSize desc):
//   # header line
//   partitionId  partitionSize  keySpaceId  nodeCount
//   ...
//   # largest_partition_size: N
//
// Stdout:
//   [WARNING] <threshold> Partitions are larger than expected … — when triggered
//   [INFO   ] summary line — always

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// ── JSON schema ───────────────────────────────────────────────────────────────

// partitionEntry mirrors the per-partition object in the JSON.
type partitionEntry struct {
	PartitionID   int      `json:"partitionId"`
	PartitionSize int64    `json:"partitionSize"`
	KeySpaceID    int      `json:"keySpaceId"`
	Nodes         []string `json:"nodes"`
}

// ── File discovery ────────────────────────────────────────────────────────────

// findJSONFiles walks dir and returns all clusterPartitionState_Metadata-Coordination_*.json paths.
func findJSONFiles(dir string) ([]string, error) {
	const prefix = "clusterPartitionState_Metadata-Coordination_"
	var files []string
	err := filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil // skip unreadable dirs
		}
		if !d.IsDir() && strings.HasPrefix(d.Name(), prefix) && strings.HasSuffix(d.Name(), ".json") {
			files = append(files, path)
		}
		return nil
	})
	return files, err
}

// ── JSON parsing ──────────────────────────────────────────────────────────────

// parseFile reads one JSON file (object keyed by partition string ID) and
// appends all unseen partitions (deduplicated by partitionId) into seen+entries.
func parseFile(path string, seen map[int]bool, entries *[]partitionEntry) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}

	// The JSON is an object: { "0": {...}, "1": {...}, ... }
	var raw map[string]partitionEntry
	if err := json.Unmarshal(data, &raw); err != nil {
		return fmt.Errorf("JSON parse: %w", err)
	}

	for _, e := range raw {
		if !seen[e.PartitionID] {
			seen[e.PartitionID] = true
			*entries = append(*entries, e)
		}
	}
	return nil
}

// ── Threshold parsing ─────────────────────────────────────────────────────────

// parseThreshold converts a size string to bytes.
// Supports binary suffixes: Gi/G, Mi/M, Ki/K (all treated as powers of 1024
// since HCP-CS uses binary sizing). Plain integers are treated as bytes.
func parseThreshold(s string) (int64, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0, nil
	}

	lower := strings.ToLower(s)
	var mult int64 = 1
	numStr := s

	switch {
	case strings.HasSuffix(lower, "gi"):
		mult = 1 << 30
		numStr = s[:len(s)-2]
	case strings.HasSuffix(lower, "mi"):
		mult = 1 << 20
		numStr = s[:len(s)-2]
	case strings.HasSuffix(lower, "ki"):
		mult = 1 << 10
		numStr = s[:len(s)-2]
	case strings.HasSuffix(lower, "g"):
		mult = 1 << 30 // treat G = Gi in storage context
		numStr = s[:len(s)-1]
	case strings.HasSuffix(lower, "m"):
		mult = 1 << 20
		numStr = s[:len(s)-1]
	case strings.HasSuffix(lower, "k"):
		mult = 1 << 10
		numStr = s[:len(s)-1]
	}

	n, err := strconv.ParseInt(strings.TrimSpace(numStr), 10, 64)
	if err != nil {
		return 0, fmt.Errorf("cannot parse threshold %q: %w", s, err)
	}
	return n * mult, nil
}

// humanBytes formats a byte count as a human-readable string (e.g. 1.02 GiB).
func humanBytes(b int64) string {
	switch {
	case b >= 1<<30:
		return fmt.Sprintf("%.2f GiB", float64(b)/float64(1<<30))
	case b >= 1<<20:
		return fmt.Sprintf("%.2f MiB", float64(b)/float64(1<<20))
	case b >= 1<<10:
		return fmt.Sprintf("%.2f KiB", float64(b)/float64(1<<10))
	default:
		return fmt.Sprintf("%d B", b)
	}
}

// ── Flat file writing ─────────────────────────────────────────────────────────

// writeFlat writes entries (pre-sorted) to a tab-separated flat file.
func writeFlat(path string, entries []partitionEntry, fileCount int) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	w := bufio.NewWriter(f)

	var maxSize int64
	if len(entries) > 0 {
		maxSize = entries[0].PartitionSize
	}

	fmt.Fprintf(w, "# partition_size_analysis — %d partitions from %d file(s)\n", len(entries), fileCount)
	fmt.Fprintf(w, "# partitionId\tpartitionSize\tkeySpaceId\tnodeCount\n")
	for _, e := range entries {
		fmt.Fprintf(w, "%d\t%d\t%d\t%d\n", e.PartitionID, e.PartitionSize, e.KeySpaceID, len(e.Nodes))
	}
	fmt.Fprintf(w, "# largest_partition_size: %d\n", maxSize)

	if err := w.Flush(); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}

// ── main ──────────────────────────────────────────────────────────────────────

func main() {
	dir       := flag.String("dir", ".", "Directory to search for JSON files")
	threshold := flag.String("threshold", "", "Split threshold string (e.g. 1Gi, 2G)")
	output    := flag.String("output", "partition_size_analysis.log", "Output flat file path")
	flag.Parse()

	// ── Discover JSON files ───────────────────────────────────────────────────
	files, err := findJSONFiles(*dir)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[ERROR ] chk_partition_sizes: walk %s: %v\n", *dir, err)
		os.Exit(1)
	}
	if len(files) == 0 {
		fmt.Fprintf(os.Stderr, "[WARN  ] chk_partition_sizes: no clusterPartitionState_Metadata-Coordination_*.json files found under %s\n", *dir)
		os.Exit(0)
	}

	// ── Parse all files (deduplicate by partitionId) ──────────────────────────
	seen := make(map[int]bool)
	var entries []partitionEntry

	for _, f := range files {
		if err := parseFile(f, seen, &entries); err != nil {
			fmt.Fprintf(os.Stderr, "[WARN  ] chk_partition_sizes: skipping %s: %v\n", f, err)
		}
	}

	if len(entries) == 0 {
		fmt.Fprintf(os.Stderr, "[WARN  ] chk_partition_sizes: no partition entries parsed\n")
		os.Exit(0)
	}

	// ── Sort by partitionSize descending ──────────────────────────────────────
	sort.Slice(entries, func(i, j int) bool {
		return entries[i].PartitionSize > entries[j].PartitionSize
	})
	maxSize := entries[0].PartitionSize

	// ── Write flat file ───────────────────────────────────────────────────────
	if err := writeFlat(*output, entries, len(files)); err != nil {
		fmt.Fprintf(os.Stderr, "[ERROR ] chk_partition_sizes: write %s: %v\n", *output, err)
		os.Exit(1)
	}

	// ── INFO summary ──────────────────────────────────────────────────────────
	fmt.Printf("[INFO   ] chk_partition_sizes: %d partitions from %d file(s); largest: %d bytes (%s) → %s\n",
		len(entries), len(files), maxSize, humanBytes(maxSize), *output)

	// ── Threshold check ───────────────────────────────────────────────────────
	if *threshold == "" {
		return
	}

	threshBytes, err := parseThreshold(*threshold)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[WARN  ] chk_partition_sizes: cannot parse threshold %q: %v\n", *threshold, err)
		return
	}
	if threshBytes <= 0 {
		return
	}

	// Check: maxSize >= 1.5 × threshBytes
	// Avoid float: use 2 × maxSize >= 3 × threshBytes
	if 2*maxSize >= 3*threshBytes {
		ratio := float64(maxSize) / float64(threshBytes)
		fmt.Printf("[WARNING] %s Partitions are larger than expected (largest: %s = %d bytes, %.2f× threshold). MDCO may need investigation.\n",
			*threshold, humanBytes(maxSize), maxSize, ratio)
	}
}
