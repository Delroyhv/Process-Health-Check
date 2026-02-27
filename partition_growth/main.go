package main

import (
    "bufio"
    "encoding/json"
    "flag"
    "fmt"
    "os"
    "sort"
    "strconv"
    "time"
)

// Event defines the structure of each JSON record.
type Event struct {
    Date           string `json:"date"`
    ParentID       int    `json:"parentId"`
    FirstChildID   int    `json:"firstChildId"`
    SecondChildID  int    `json:"secondChildId"`
    LeaderNodeInfo string `json:"leaderNodeInfo"`
}

func monthName(m int) string {
    return time.Month(m).String()[:3]
}
func daysInMonth(year int, month int) int {
    // day 0 of next month is the last day of the target month
    return time.Date(year, time.Month(month)+1, 0, 0, 0, 0, 0, time.UTC).Day()
}

func main() {
    // Command‑line flags
    filePath := flag.String("f", "", "path to JSON input file (required)")
    day := flag.Int("d", 0, "filter by day of month (1‑31)")
    month := flag.Int("m", 0, "filter by month (1‑12)")
    year := flag.Int("y", 0, "filter by year")
    allYears := flag.Bool("a", false, "print all data summarized by year (ignores -y filter)")
    top := flag.Bool("t", false, "show top results; use with -y and one of -week or -month")
    topMonth := flag.Bool("month", false, "with -t and -y: show top 5 months in that year")
    topWeek := flag.Bool("week", false, "with -t and -y: show top 5 ISO weeks in that year")

    flag.Usage = func() {
        fmt.Fprintf(os.Stderr, "Usage:\n")
        fmt.Fprintf(os.Stderr, "  %s -f <file> [options]\n\n", os.Args[0])
        fmt.Fprintf(os.Stderr, "Options:\n")
        fmt.Fprintf(os.Stderr, "  -f <path>          Path to JSON input file (required)\n")
        fmt.Fprintf(os.Stderr, "  -y <year>          Filter by year; prints year summary only when provided\n")
        fmt.Fprintf(os.Stderr, "  -m <month>         Filter by month (1-12); with -y prints in-month weekly summary and total\n")
        fmt.Fprintf(os.Stderr, "  -d <day>           Filter by day; day count prints only when -d -m -y are all provided\n")
        fmt.Fprintf(os.Stderr, "  -a                 Print all data summarized by year (sorted) with grand total\n")
        fmt.Fprintf(os.Stderr, "  -t                 Show top results (requires -y and one of -week or -month)\n")
        fmt.Fprintf(os.Stderr, "  -week              With -t and -y: show top 5 ISO weeks in that year\n")
        fmt.Fprintf(os.Stderr, "  -month             With -t and -y: show top 5 months in that year\n")
        fmt.Fprintf(os.Stderr, "\nExamples:\n")
        fmt.Fprintf(os.Stderr, "  %s -f data.json -y 2025 -m 1\n", os.Args[0])
        fmt.Fprintf(os.Stderr, "  %s -f data.json -y 2025 -m 1 -d 3\n", os.Args[0])
        fmt.Fprintf(os.Stderr, "  %s -f data.json -a\n", os.Args[0])
        fmt.Fprintf(os.Stderr, "  %s -f data.json -y 2025 -t -month   # Top 5 months in 2025\n", os.Args[0])
        fmt.Fprintf(os.Stderr, "  %s -f data.json -y 2025 -t -week    # Top 5 ISO weeks in 2025\n", os.Args[0])
    }

    flag.Parse()

    if *filePath == "" {
        fmt.Fprintln(os.Stderr, "error: -f is required")
        flag.Usage()
        os.Exit(1)
    }

    file, err := os.Open(*filePath)
    if err != nil {
        fmt.Fprintf(os.Stderr, "error opening file %s: %v\n", *filePath, err)
        os.Exit(1)
    }
    defer file.Close()

    decoder := json.NewDecoder(bufio.NewReader(file))
    token, err := decoder.Token()
    if err != nil {
        fmt.Fprintf(os.Stderr, "error reading JSON: %v\n", err)
        os.Exit(1)
    }

    // Aggregation maps
    perDay := make(map[string]int)
    perWeek := make(map[string]int)
    perMonth := make(map[string]int)
    perYear := make(map[int]int)
    totalEvents := 0

    // Additional aggregations for conditional reporting
    monthWeekBuckets := make(map[int]int) // week 1..5 within selected month/year
    monthTotal := 0
    selectedMonth := *month
    selectedYear := *year

    perISOWeekAll := make(map[string]int) // key: "YYYY-Www" using ISO week-year, always collected

    shouldInclude := func(t time.Time) bool {
        if *year != 0 && t.Year() != *year {
            return false
        }
        if *month != 0 && int(t.Month()) != *month {
            return false
        }
        if *day != 0 && t.Day() != *day {
            return false
        }
        return true
    }

    layout := "Jan 2, 2006, 3:04:05 PM"

    processEvent := func(evt Event) {
        dt, err := time.Parse(layout, evt.Date)
        if err != nil {
            fmt.Fprintf(os.Stderr, "error parsing date %q: %v\n", evt.Date, err)
            return
        }
        isoYear, isoWeek := dt.ISOWeek()
        isoWeekKey := fmt.Sprintf("%04d-W%02d", isoYear, isoWeek)
        perISOWeekAll[isoWeekKey]++

        // Always collect global year/month for -a mode
        _, _ = dt.ISOWeek()
        monthKey := dt.Format("2006-01")
        perMonth[monthKey]++
        perYear[dt.Year()]++

        if !shouldInclude(dt) {
            return
        }

        // Per-day for exact day prints (suppressed unless -d -m -y are all used)
        dayKey := dt.Format("2006-01-02")
        perDay[dayKey]++

        // Strict in-month "week" bucket (1..5), no ISO spillovers
        if selectedMonth != 0 && selectedYear != 0 &&
            int(dt.Month()) == selectedMonth && dt.Year() == selectedYear {
            w := (dt.Day()-1)/7 + 1
            monthWeekBuckets[w]++
            monthTotal++
        }

        // Maintain generic perWeek only for backward compatibility (not printed unless needed)
        _, iw := dt.ISOWeek()
        weekKey := fmt.Sprintf("%d-W%02d", dt.Year(), iw)
        perWeek[weekKey]++

        totalEvents++
    }

    if delim, ok := token.(json.Delim); ok && delim == '[' {
        // JSON array
        for decoder.More() {
            var evt Event
            if err := decoder.Decode(&evt); err != nil {
                fmt.Fprintf(os.Stderr, "error decoding JSON element: %v\n", err)
                os.Exit(1)
            }
            processEvent(evt)
        }
        if _, err := decoder.Token(); err != nil {
            fmt.Fprintf(os.Stderr, "error closing array: %v\n", err)
            os.Exit(1)
        }
    } else {
        // Stream of objects
        file.Seek(0, 0)
        decoder = json.NewDecoder(bufio.NewReader(file))
        for {
            var evt Event
            if err := decoder.Decode(&evt); err != nil {
                if err.Error() == "EOF" {
                    break
                }
                fmt.Fprintf(os.Stderr, "error decoding JSON object: %v\n", err)
                os.Exit(1)
            }
            processEvent(evt)
        }
    }

    // ----- Output logic -----

    if *top && *year != 0 {
        // Top 5 months in the specified year
        if *topMonth {
            type kv struct {
                Key string
                Val int
                M   int
            }
            rows := make([]kv, 0, 12)
            yprefix := fmt.Sprintf("%04d-", *year)
            for k, v := range perMonth {
                if len(k) >= 7 && k[:5] == yprefix {
                    // k is "YYYY-MM"
                    mm, _ := strconv.Atoi(k[5:7])
                    rows = append(rows, kv{Key: k, Val: v, M: mm})
                }
            }
            sort.Slice(rows, func(i, j int) bool { return rows[i].Val > rows[j].Val })
            if len(rows) > 5 {
                rows = rows[:5]
            }
            fmt.Printf("Top 5 months in %d:\n", *year)
            for _, r := range rows {
                fmt.Printf("%s %d: %d\n", monthName(r.M), *year, r.Val)
            }
            fmt.Println()
        }
        // Top 5 ISO weeks in the specified year
        if *topWeek {
            type wk struct {
                Key string
                Val int
                W   int
            }
            yprefix := fmt.Sprintf("%04d-", *year)
            weeks := make([]wk, 0, 60)
            for k, v := range perISOWeekAll {
                if len(k) >= 7 && k[:5] == yprefix {
                    // format "YYYY-Www"
                    w, _ := strconv.Atoi(k[6:8])
                    weeks = append(weeks, wk{Key: k, Val: v, W: w})
                }
            }
            sort.Slice(weeks, func(i, j int) bool { return weeks[i].Val > weeks[j].Val })
            if len(weeks) > 5 {
                weeks = weeks[:5]
            }
            fmt.Printf("Top 5 ISO weeks in %d:\n", *year)
            for _, r := range weeks {
                fmt.Printf("%s: %d\n", r.Key, r.Val)
            }
            fmt.Println()
        }
    }

    // 1) If -m and -y are provided, print weekly summary for that month and the monthly total.
    if *month != 0 && *year != 0 {
        fmt.Printf("%s %d weekly summary:\n", monthName(*month), *year)
        dim := daysInMonth(*year, *month)
        numWeeks := (dim + 6) / 7 // up to 5 weeks
        grand := 0
        for w := 1; w <= numWeeks; w++ {
            start := (w-1)*7 + 1
            end := w * 7
            if end > dim {
                end = dim
            }
            count := monthWeekBuckets[w]
            fmt.Printf("Week %d: %s %d–%d, %d: %d\n", w, monthName(*month), start, end, *year, count)
            grand += count
        }
        fmt.Printf("Total for %s %d: %d\n", monthName(*month), *year, grand)
        fmt.Println()
    }

    // 2) If -d, -m, and -y are all provided, print the exact day count.
    if *day != 0 && *month != 0 && *year != 0 {
        key := fmt.Sprintf("%04d-%02d-%02d", *year, *month, *day)
        fmt.Printf("Day %s %d, %04d: %d\n", monthName(*month), *day, *year, perDay[key])
        fmt.Println()
    }

    // 3) Year summary only when -y is used (single year) OR -a is used (all years).
    if *year != 0 && !*allYears {
        // Single specified year
        fmt.Println("Counts for year:")
        fmt.Printf("%d: %d\n", *year, perYear[*year])
        fmt.Println()
    }

    if *allYears {
        years := make([]int, 0, len(perYear))
        for y := range perYear {
            years = append(years, y)
        }
        sort.Ints(years)
        fmt.Println("Counts per year:")
        sum := 0
        for _, y := range years {
            v := perYear[y]
            fmt.Printf("%d: %d\n", y, v)
            sum += v
        }
        fmt.Printf("Total for years: %d\n", sum)
        fmt.Println()
    }

    // 4) Unless explicitly requested above, do not print generic per-day/per-week/per-month tables.
    // Print overall total for the filtered set (respects -d/-m/-y filters).
    fmt.Printf("Overall total (filtered): %d\n", totalEvents)
}
