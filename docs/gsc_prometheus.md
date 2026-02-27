# NAME

gsc_prometheus.sh - extract a Prometheus snapshot and run it in Docker
or Podman

# SYNOPSIS

**sudo gsc_prometheus.sh** **-s** *SR* **-c** *CUSTOMER* **-f** *PSNAP*
**-b** *BASEDIR* \[**options**\]

# DESCRIPTION

**gsc_prometheus.sh** extracts a Prometheus snapshot archive
(*psnap\_\*.tar.xz*) into a working directory and starts a Prometheus
container (using Docker or Podman, auto-detected) that serves the
snapshot data.

It automatically selects the lowest free TCP port in the range
**9090–9200** by scanning ports already bound by the system and mapped
to running containers. The following ports are always excluded as they
are reserved for common exporters: **9093** (Alertmanager), **9100**
(node_exporter), **8080** (generic HTTP), **9115** (blackbox_exporter),
**9116** (SNMP exporter), **9104** (mysqld_exporter).

When the container starts successfully the selected port is printed:

>     [ OK  ] Prometheus for CUSTOMER/SR started on port PORT.

If a *healthcheck.conf* file is found in the same directory as the
snapshot file, **_prom_port** is automatically updated to the selected
port. If no *healthcheck.conf* is present, note the port and supply it
to **expand_hcpcs_support.sh --healthcheck-only -u -p *PORT*** before
running **runchk.sh**. See **hcpcs-health-check**(7).

The container is named *gsc_prometheus_CUSTOMER_SR_PORT* and is started
with **--rm** so it is removed automatically when stopped unless
**--keep-container** is given.

# OPTIONS

## Required

**-c**, **--customer** *NAME*  
Customer name. Used to construct the container name and the working
directory path under *BASEDIR*.

**-s**, **--service-request** *SR*  
Service request or case number. Combined with *CUSTOMER* to form the
unique working directory and container name.

**-f**, **--snapshot-file** *PATH*  
Path to the Prometheus snapshot archive (*psnap\_\*.tar.xz*). Must be an
existing file.

**-b**, **--base-directory** *PATH*  
Base directory under which per-customer working directories are created.
If it does not exist it will be created. The final data path is
*BASEDIR/CUSTOMER/SR/prom/data*.

## Optional

**-C**, **--config-file** *PATH*  
Key=value config file. Supports the same keys as the CLI options:
*customer*, *service_request*, *snapshot_file*, *base_directory*,
*min_port*, *max_port*, *exclude_ports*, *engine*, *image*. CLI options
take precedence over config file values.

**--engine auto\|docker\|podman**  
Force the container engine. Default: **auto** (prefers Docker if both
are present).

**--image IMAGE**  
Prometheus container image to use. Default:
*docker.io/prom/prometheus:latest*

**--replace**  
Remove any existing container with the same name before starting.

**--keep-container**  
Start the container without **--rm**; the container persists after it is
stopped.

**--min-port N**  
Lowest port to consider. Default: *9090*

**--max-port N**  
Highest port to consider. Default: *9200*

**--exclude-port N**  
Exclude an additional port from selection. May be repeated.

**-e**, **--estimate**  
Check available disk space before extracting and warn or abort if
insufficient.

**--estimate-only**  
Print space estimate and exit without extracting or starting the
container.

**--no-space-check**  
Disable free-space checking even when **-e** was given.

**--debug**  
Enable verbose diagnostic output.

**--no-color**  
Disable ANSI colour output.

**--version**  
Print the script version and exit.

**-h**, **--help**  
Print a usage summary and exit.

# EXIT STATUS

**0**  
Container started successfully.

**1**  
A required argument was missing, the snapshot file was not found, no
free port was available, or the container failed to start.

# ENVIRONMENT

**GSC_LIB_PATH**  
Override the path to *gsc_core.sh* (default: same directory as the
script).

**GSC_PROM_LOG_DIR**  
Override the directory used to store the last-used-port file. Default:
*/var/log/gsc_prometheus*

# FILES

*BASEDIR/CUSTOMER/SR/prom/data/*  
Extracted snapshot data directory. Mounted into the container as
*/prometheus*.

*BASEDIR/CUSTOMER/SR/prom/prometheus.yml*  
Minimal Prometheus configuration written by the script.

*/var/log/gsc_prometheus/v*VERSION*/last_used_port.txt*  
Records the last allocated port so subsequent invocations start scanning
from the next port rather than 9090.

# EXAMPLES

## Basic invocation (Step 3 of workflow)

    sudo gsc_prometheus.sh \
        -s 05304447 \
        -c AcmeCorp \
        -f psnap_2025-Nov-26_20-48-48.tar.xz \
        -b /opt/prom_instances

## Force Podman and a specific port range

    sudo gsc_prometheus.sh \
        -s 05304447 -c AcmeCorp \
        -f psnap_2025-Nov-26_20-48-48.tar.xz \
        -b /opt/prom_instances \
        --engine podman --min-port 9150 --max-port 9160

## Check space before extracting a large snapshot

    sudo gsc_prometheus.sh \
        -s 05304447 -c AcmeCorp \
        -f psnap_2025-Nov-26_20-48-48.tar.xz \
        -b /opt/prom_instances --estimate-only

## Replace an existing container for the same SR

    sudo gsc_prometheus.sh \
        -s 05304447 -c AcmeCorp \
        -f psnap_2025-Nov-26_20-48-48.tar.xz \
        -b /opt/prom_instances --replace

# SEE ALSO

**expand_hcpcs_support**(1), **runchk**(1), **hcpcs-health-check**(7),
**docker**(1), **podman**(1)

# AUTHORS

Hitachi Vantara GSC
