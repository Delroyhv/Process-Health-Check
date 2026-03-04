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

func getQuarter(m time.Month) int {
    return (int(m)-1)/3 + 1
}

func main() {
    // Command‑line flags
    filePath := flag.String("f", "", "path to JSON input file (required)")
    day := flag.Int("d", 0, "filter by day of month (1‑31)")
    month := flag.Int("m", 0, "filter by month (1‑12)")
    year := flag.Int("y", 0, "filter by year")
    allYears := flag.Bool("a", false, "print all data summarized by year, quarter, and last 30 days")
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
        fmt.Fprintf(os.Stderr, "  -a                 Print all data summarized by year, quarter, and last 30 days\n")
        fmt.Fprintf(os.Stderr, "  -t                 Show top results (requires -y and one of -week or -month)\n")
        fmt.Fprintf(os.Stderr, "  -week              With -t and -y: show top 5 ISO weeks in that year\n")
        fmt.Fprintf(os.Stderr, "  -month             With -t and -y: show top 5 months in that year\n")
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
    perQuarter := make(map[string]int) // "YYYY-QN"
    var allDates []time.Time
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
        allDates = append(allDates, dt)
        isoYear, isoWeek := dt.ISOWeek()
        isoWeekKey := fmt.Sprintf("%04d-W%02d", isoYear, isoWeek)
        perISOWeekAll[isoWeekKey]++

        monthKey := dt.Format("2006-01")
        perMonth[monthKey]++
        perYear[dt.Year()]++
        
        qKey := fmt.Sprintf("%d-Q%d", dt.Year(), getQuarter(dt.Month()))
        perQuarter[qKey]++

        if !shouldInclude(dt) {
            return
        }

        dayKey := dt.Format("2006-01-02")
        perDay[dayKey]++

        if selectedMonth != 0 && selectedYear != 0 &&
            int(dt.Month()) == selectedMonth && dt.Year() == selectedYear {
            w := (dt.Day()-1)/7 + 1
            monthWeekBuckets[w]++
            monthTotal++
        }

        _, iw := dt.ISOWeek()
        weekKey := fmt.Sprintf("%d-W%02d", dt.Year(), iw)
        perWeek[weekKey]++

        totalEvents++
    }

    if delim, ok := token.(json.Delim); ok && delim == '[' {
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

    if *month != 0 && *year != 0 {
        fmt.Printf("%s %d weekly summary:\n", monthName(*month), *year)
        dim := daysInMonth(*year, *month)
        numWeeks := (dim + 6) / 7
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

    if *day != 0 && *month != 0 && *year != 0 {
        key := fmt.Sprintf("%04d-%02d-%02d", *year, *month, *day)
        fmt.Printf("Day %s %d, %04d: %d\n", monthName(*month), *day, *year, perDay[key])
        fmt.Println()
    }

    if *year != 0 && !*allYears {
        fmt.Println("Counts for year:")
        fmt.Printf("%d: %d\n", *year, perYear[*year])
        fmt.Println()
    }

    if *allYears {
        fmt.Println("--- Yearly Partition Growth ---")
        years := make([]int, 0, len(perYear))
        for y := range perYear {
            years = append(years, y)
        }
        sort.Ints(years)
        sum := 0
        for _, y := range years {
            v := perYear[y]
            fmt.Printf("%d: %d splits\n", y, v)
            sum += v
        }
        fmt.Println()

        fmt.Println("--- Quarterly Partition Growth ---")
        qs := make([]string, 0, len(perQuarter))
        for q := range perQuarter {
            qs = append(qs, q)
        }
        sort.Strings(qs)
        for _, q := range qs {
            fmt.Printf("%s: %d splits\n", q, perQuarter[q])
        }
        fmt.Println()

        fmt.Println("--- Monthly Partition Growth ---")
        ms := make([]string, 0, len(perMonth))
        for m := range perMonth {
            ms = append(ms, m)
        }
        sort.Strings(ms)
        for _, m := range ms {
            fmt.Printf("%s: %d splits\n", m, perMonth[m])
        }
        fmt.Println()

        fmt.Println("--- Last 30 Days Partition Growth ---")
        if len(allDates) > 0 {
            sort.Slice(allDates, func(i, j int) bool { return allDates[i].After(allDates[j]) })
            latest := allDates[0]
            thirtyDaysAgo := latest.AddDate(0, 0, -30)
            count30 := 0
            for _, d := range allDates {
                if d.After(thirtyDaysAgo) || d.Equal(thirtyDaysAgo) {
                    count30++
                } else {
                    break
                }
            }
            fmt.Printf("From %s to %s: %d splits\n", thirtyDaysAgo.Format("2006-01-02"), latest.Format("2006-01-02"), count30)
        } else {
            fmt.Println("No data available.")
        }
        fmt.Println()
        
        fmt.Printf("Grand Total (All Years): %d splits\n", sum)
        fmt.Println()
    }

    if !*allYears && *year == 0 && *month == 0 && *day == 0 {
        fmt.Printf("Overall total (unfiltered): %d\n", len(allDates))
    }
}
