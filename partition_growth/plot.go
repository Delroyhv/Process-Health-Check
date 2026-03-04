package main

import (
	"fmt"
)

func plotLine(title string, labels []string, values []int, height int) {
	fmt.Printf("\n--- %s ---\n", title)
	if len(values) == 0 {
		return
	}

	maxVal := 0
	for _, v := range values {
		if v > maxVal {
			maxVal = v
		}
	}
	if maxVal == 0 {
		maxVal = 1
	}

	for h := height; h >= 0; h-- {
		threshold := (h * maxVal) / height
		fmt.Printf("%5d |", threshold)
		for _, v := range values {
			if v >= threshold {
				fmt.Print("  *  ")
			} else {
				fmt.Print("     ")
			}
		}
		fmt.Println()
	}

	fmt.Print("      +")
	for i := 0; i < len(values); i++ {
		fmt.Print("-----")
	}
	fmt.Println()

	fmt.Print("       ")
	for _, l := range labels {
		fmt.Printf(" %-4s", l)
	}
	fmt.Println("\n")
}

func main() {
	plotLine("Year-to-Year Partition Growth", []string{"2023", "2024", "2025", "2026"}, []int{49, 715, 1009, 57}, 10)
	plotLine("Quarterly Partition Growth (2024-2025)", []string{"24Q1", "24Q2", "24Q3", "24Q4", "25Q1", "25Q2", "25Q3", "25Q4"}, []int{0, 69, 321, 325, 345, 265, 266, 133}, 10)
	plotLine("Weekly Growth - Feb 2025 Peak", []string{"W1", "W2", "W3", "W4"}, []int{53, 26, 24, 24}, 5)
	plotLine("Weekly Growth - July 2025 Peak", []string{"W1", "W2", "W3", "W4", "W5"}, []int{50, 30, 19, 15, 8}, 5)
}
