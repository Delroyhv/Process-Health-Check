package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"os"
)

type SNodeConfig struct {
	Label          string `json:"label"`
	Host           string `json:"host"`
	HTTPS          bool   `json:"https"`
	Port           int    `json:"port"`
	MaxConnections int    `json:"maxConnections"`
	State          string `json:"state"`
}

type StorageComponent struct {
	StorageType string      `json:"storageType"`
	Config      SNodeConfig `json:"storageComponentConfig"`
}

const (
	wantType    = "HCPS_S3"
	wantPort    = 443
	wantMaxConn = 1024
)

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
	file   := flag.String("file", "", "S-node config JSON file")
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

	var components []StorageComponent
	if err := json.Unmarshal(data, &components); err != nil {
		fmt.Fprintln(os.Stderr, "error parsing JSON:", err)
		os.Exit(1)
	}

	out, err := os.Create(*output)
	if err != nil {
		fmt.Fprintln(os.Stderr, "error creating output:", err)
		os.Exit(1)
	}
	defer out.Close()

	total     := len(components)
	sNodeCnt  := 0
	nonType   := []StorageComponent{}
	nonHTTPS  := []StorageComponent{}
	nonPort   := []StorageComponent{}
	nonConn   := []StorageComponent{}

	for _, sc := range components {
		if sc.StorageType == wantType {
			sNodeCnt++
		} else {
			nonType = append(nonType, sc)
		}
		if !sc.Config.HTTPS {
			nonHTTPS = append(nonHTTPS, sc)
		}
		if sc.Config.Port != wantPort {
			nonPort = append(nonPort, sc)
		}
		// MaxConnections == 0 means field absent in JSON; treat as default
		if sc.Config.MaxConnections != 0 && sc.Config.MaxConnections != wantMaxConn {
			nonConn = append(nonConn, sc)
		}
	}

	fmt.Fprintf(out, "INFO: Total Storage Components: %d, number of S-nodes: %d\n", total, sNodeCnt)

	if len(nonType) > 0 {
		fmt.Fprintf(out, "WARNING: Detected %d non S-node storage components (not %s)\n",
			len(nonType), wantType)
	}
	if len(nonHTTPS) > 0 {
		fmt.Fprintf(out, "WARNING: Detected %d storage components with a non-default protocol (http)\n",
			len(nonHTTPS))
	}
	if len(nonPort) > 0 {
		fmt.Fprintf(out, "WARNING: Detected %d storage components with non-%d port\n",
			len(nonPort), wantPort)
	}
	if len(nonConn) > 0 {
		fmt.Fprintf(out, "WARNING: Detected %d storage components with non-default maxConnections (default: %d)\n",
			len(nonConn), wantMaxConn)
		for _, sc := range nonConn {
			fmt.Fprintf(out, "  %s\t\t%s\t\t%d\n",
				sc.Config.Label, sc.Config.Host, sc.Config.MaxConnections)
		}
	}

	fmt.Fprintf(os.Stderr, "[INFO ] chk_snodes: wrote %s (%d components)\n", *output, total)
}
