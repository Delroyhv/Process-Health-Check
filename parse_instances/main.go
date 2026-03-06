package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"strings"
)

type Service struct {
	Name   string `json:"name"`
	Status string `json:"status"`
}

type Instance struct {
	IP       string    `json:"externalIpAddress"`
	Services []Service `json:"services"`
}

func readNoComment(path string) ([]byte, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	if len(data) > 0 && data[0] == '#' {
		idx := bytes.IndexByte(data, '\n')
		if idx < 0 {
			return []byte("[]"), nil
		}
		return data[idx+1:], nil
	}
	return data, nil
}

func main() {
	file   := flag.String("file", "", "input JSON file (instances)")
	output := flag.String("output", "", "output log file (required)")
	flag.Usage = func() {
		fmt.Fprintf(os.Stderr, "Usage: %s --file <json> --output <log>\n", os.Args[0])
	}
	flag.Parse()

	if *file == "" || *output == "" {
		flag.Usage()
		os.Exit(1)
	}

	data, err := readNoComment(*file)
	if err != nil {
		fmt.Fprintln(os.Stderr, "error reading", *file, ":", err)
		os.Exit(1)
	}

	var instances []Instance
	if err := json.Unmarshal(data, &instances); err != nil {
		fmt.Fprintln(os.Stderr, "error parsing JSON:", err)
		os.Exit(1)
	}
	if len(instances) == 0 {
		fmt.Fprintln(os.Stderr, "ERROR: no instances found in", *file)
		os.Exit(1)
	}

	out, err := os.Create(*output)
	if err != nil {
		fmt.Fprintln(os.Stderr, "error creating output:", err)
		os.Exit(1)
	}
	defer out.Close()

	// Service registry preserving insertion order
	type svcEntry struct{ nodes []string }
	svcIndex := map[string]int{}
	svcNames := []string{}
	svcData  := []*svcEntry{}

	fmt.Fprintf(out, "Parsing %s file\n", *file)
	fmt.Fprintf(out, "# Service information for HCP-CS: %s\n", *file)
	fmt.Fprintf(out, "%d nodes\n", len(instances))
	fmt.Fprintln(out, "======== Display HCP-CS services on each node: ")

	for i, inst := range instances {
		labels := make([]string, 0, len(inst.Services))
		for _, svc := range inst.Services {
			label := svc.Name
			if svc.Status != "" && svc.Status != "Healthy" {
				label += "(" + svc.Status + ")"
			}
			labels = append(labels, label)

			if _, exists := svcIndex[svc.Name]; !exists {
				svcIndex[svc.Name] = len(svcNames)
				svcNames = append(svcNames, svc.Name)
				svcData  = append(svcData, &svcEntry{})
			}
			entry := svcData[svcIndex[svc.Name]]
			node := inst.IP
			if svc.Status != "" && svc.Status != "Healthy" {
				node += "(" + svc.Status + ")"
			}
			entry.nodes = append(entry.nodes, node)
		}
		fmt.Fprintf(out, "[%d] %s: %d services= %s\n",
			i+1, inst.IP, len(inst.Services), strings.Join(labels, ", "))
	}

	fmt.Fprintf(out, "======== Display all %d HCP-CS services and the nodes they are running on: \n",
		len(svcNames))
	for i, name := range svcNames {
		nodes := svcData[i].nodes
		s := "s"
		if len(nodes) == 1 {
			s = ""
		}
		fmt.Fprintf(out, "%d)%s: %d node%s: %s\n",
			i+1, name, len(nodes), s, strings.Join(nodes, ", "))
	}

	fmt.Fprintf(os.Stderr, "[INFO ] parse_instances: wrote %s (%d nodes, %d services)\n",
		*output, len(instances), len(svcNames))
}
