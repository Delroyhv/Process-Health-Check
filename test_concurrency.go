package main

import (
	"bufio"
	"fmt"
	"os/exec"
	"strings"
	"sync"
	"time"
)

type TestCase struct {
	ID   int
	Cust string
	SR   string
	Snap string
	Dir  string
}

func main() {
	testCases := []TestCase{
		{1, "Acme", "05455380", "/ci/05455380/2026-02-23_17-04-47/psnap_2026-Feb-23_11-53-12.tar.xz", "/ci/05455380/2026-02-23_17-04-47"},
		{2, "Globex", "05459227", "/ci/05459227/2026-02-25_03-31-47/psnap_2026-Feb-25_14-00-31.tar.xz", "/ci/05459227/2026-02-25_03-31-47"},
		{3, "Soylent", "05400896", "/ci/05400896/2026-01-05_19-21-11/psnap_2026-Jan-05_13-36-41.tar.xz", "/ci/05400896/2026-01-05_19-21-11"},
	}

	var wg sync.WaitGroup
	startGate := make(chan struct{})

	fmt.Println("[TEST] Starting randomized concurrency test with real snapshots...")
	fmt.Println("[TEST] Force syncing latest gsc_prometheus.sh and gsc_core.sh...")
	exec.Command("sudo", "rsync", "-av", "/home/dablake/src/Process-Health-Check/gsc_prometheus.sh", "/home/dablake/src/Process-Health-Check/gsc_core.sh", "/home/dablake/.local/bin/").Run()
	
	// Apply the robust seeding fix to the local binary if not already there
	exec.Command("sudo", "sed", "-i", "s/RANDOM=\\$.*/[[ \"${_last_used_port}\" =~ ^[0-9]+$ ]] || _last_used_port=9090; RANDOM=$(( _last_used_port + $$ ))/", "/home/dablake/.local/bin/gsc_prometheus.sh").Run()

	fmt.Println("[TEST] Initial cleanup...")
	exec.Command("sudo", "/home/dablake/.local/bin/gsc_prometheus.sh", "--cleanup", "--override=y", "-b", ".").Run()

	for _, tc := range testCases {
		wg.Add(1)
		go func(t TestCase) {
			defer wg.Done()
			<-startGate

			cmd := exec.Command("sudo", "/home/dablake/.local/bin/gsc_prometheus.sh",
				"-c", t.Cust,
				"-s", t.SR,
				"-f", t.Snap,
				"-b", ".", "--replace", "--no-space-check")
			
			cmd.Dir = t.Dir

			output, err := cmd.CombinedOutput()
			
			port := "FAILED"
			if err == nil {
				scanner := bufio.NewScanner(strings.NewReader(string(output)))
				for scanner.Scan() {
					line := scanner.Text()
					if strings.Contains(line, "started on port") {
						parts := strings.Fields(line)
						port = strings.Trim(parts[len(parts)-1], ".")
					}
				}
			} else {
				// Search output for line numbers or errors
				fmt.Printf("[Instance %d] ERROR: %v\nOutput: %s\n", t.ID, err, string(output))
			}
			fmt.Printf("[Instance %d] %s (%s): Port %s\n", t.ID, t.Cust, t.SR, port)
		}(tc)
	}

	time.Sleep(1 * time.Second)
	fmt.Println("[TEST] GO! Releasing all instances...")
	close(startGate)
	wg.Wait()

	fmt.Println("\n[TEST] Final Container Mappings in Podman:")
	out, _ := exec.Command("podman", "ps", "--format", "{{.Names}} -> {{.Ports}}", "--filter", "name=gsc_prometheus").Output()
	fmt.Print(string(out))

	fmt.Println("\n[TEST] Cleanup...")
	exec.Command("sudo", "/home/dablake/.local/bin/gsc_prometheus.sh", "--cleanup", "--override=y", "-b", ".").Run()
}
