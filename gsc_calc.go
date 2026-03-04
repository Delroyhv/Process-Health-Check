package main

import (
	"flag"
	"fmt"
	"os"
	"strconv"
)

func main() {
	var op string
	var val1, val2 float64
	var err error

	flag.StringVar(&op, "op", "", "Operation: >, <, ==, !=, +, -, *, /")
	flag.Parse()

	args := flag.Args()
	if len(args) < 2 {
		os.Exit(1)
	}

	val1, err = strconv.ParseFloat(args[0], 64)
	if err != nil {
		os.Exit(1)
	}
	val2, err = strconv.ParseFloat(args[1], 64)
	if err != nil {
		os.Exit(1)
	}

	switch op {
	case ">":
		if val1 > val2 {
			fmt.Printf("%g > %g\n", val1, val2)
		}
	case "<":
		if val1 < val2 {
			fmt.Printf("%g < %g\n", val1, val2)
		}
	case "==":
		if val1 == val2 {
			fmt.Printf("%g == %g\n", val1, val2)
		}
	case "!=":
		if val1 != val2 {
			fmt.Printf("%g != %g\n", val1, val2)
		}
	case "+":
		fmt.Printf("%g\n", val1+val2)
	case "-":
		fmt.Printf("%g\n", val1-val2)
	case "*":
		fmt.Printf("%g\n", val1*val2)
	case "/":
		if val2 != 0 {
			fmt.Printf("%g\n", val1/val2)
		} else {
			os.Exit(1)
		}
	default:
		os.Exit(1)
	}
}
