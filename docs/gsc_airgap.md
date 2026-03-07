# NAME

gsc_airgap.sh - load and start Prometheus + Grafana on an air-gapped
system

# SYNOPSIS

**sudo gsc_airgap.sh** **--save-images** *OUTDIR* \[**options**\]

**sudo gsc_airgap.sh** **--load-images** *BUNDLEDIR* \[**options**\]

**sudo gsc_airgap.sh** **--start** **-c** *CUSTOMER* **-s** *SR* **-f**
*PSNAP* **-b** *BASEDIR* \[**options**\]

**sudo gsc_airgap.sh** **--stop** \[**options**\]

# DESCRIPTION

**gsc_airgap.sh** manages the full lifecycle of Prometheus and Grafana
containers on systems that have no outbound internet access (air-gapped
environments).

On a network-connected host use **--save-images** to pull both container
images and export them to a portable tar bundle directory. Transfer that
directory to the air-gapped host (USB, SCP, etc.) and use
**--load-images** to import the images into the local container engine.
Once loaded, use **--start** to extract a Prometheus snapshot (psnap),
start Prometheus, and start Grafana pre-provisioned with the Prometheus
datasource. **--stop** stops and removes both containers.

All volume mounts include the **:z** SELinux shared-relabel flag so the
containers can read their data directories on SELinux-enforcing systems
(RHEL, AlmaLinux, Fedora). The flag is a no-op on non-SELinux hosts.

Port selection for Prometheus is automatic: a random free TCP port is
chosen from the range **9090–9599** (configurable with **--min-port**
and **--max-port**), skipping reserved exporter ports (9093, 9100, 8080,
9115, 9116, 9104) and any ports already mapped by running containers.

If a *healthcheck.conf* file exists in the same directory as the
snapshot file, **\_prom_port** is automatically updated to the selected
port after Prometheus starts.

# MODES

**--save-images *OUTDIR***  
Pull *prom/prometheus* and *grafana/grafana* images on the current
(connected) host and write them to *prometheus\_\<tag\>.tar* and
*grafana\_\<tag\>.tar* in *OUTDIR*. Also writes *airgap_manifest.txt*
recording image names, filenames, and digests. Run this mode on a host
with internet access before transporting the bundle to the target
system.

**--load-images *BUNDLEDIR***  
Read *BUNDLEDIR/airgap_manifest.txt* and load each image tar into the
container engine with **docker load** / **podman load**. Idempotent:
images that are already present are skipped without error. Run this mode
on the air-gapped host after the bundle has been transported.

**--start**  
Extract the Prometheus snapshot archive, start a Prometheus container,
then start a Grafana container pre-provisioned with the Prometheus
datasource. Requires **-c**, **-s**, **-f**, and **-b**. Both images
must already be loaded (see **--load-images**). Grafana startup is
skipped with a warning when its image is absent; Prometheus still
starts.

**--stop**  
Stop and remove all Prometheus containers matching *gsc_prometheus\_\**
and all Grafana containers matching *gsc_grafana\_\**. Add **--volume**
to also delete the extracted data directories.

# OPTIONS

## Prometheus options (required for --start)

**-c**, **--customer** *NAME*  
Customer name. Used to construct the container name and working
directory path under *BASEDIR*.

**-s**, **--service-request** *SR*  
Service request or case number. Combined with *CUSTOMER* to form unique
container names and directory paths.

**-f**, **--snapshot-file** *PATH*  
Path to the Prometheus snapshot archive (*psnap\_\*.tar.xz*). Must be an
existing file.

**-b**, **--base-directory** *PATH*  
Base directory under which per-customer working directories are created.
Created automatically if it does not exist. The Prometheus data path is
*BASEDIR/CUSTOMER/SR/prom/data*; Grafana provisioning is at
*BASEDIR/CUSTOMER/SR/grafana/*.

## Grafana options (optional for --start)

**-D**, **--dashboard** *FILE*  
Dashboard JSON file or archive (*.zip*, *.tar.gz*, *.tar.xz*). May be
repeated to load multiple dashboards. When omitted, Grafana starts with
an empty dashboard folder.

**-g**, **--grafana-port** *PORT*  
Port to expose Grafana on the host. Default: *3000*

**-i**, **--datasource** *IP:PORT*  
Prometheus datasource address. Default: automatically derived from the
port selected for Prometheus (*http://localhost:PORT*).

**--admin-password *PASSWORD***  
Grafana admin account password. Default: *admin*

## Image options

**--prom-tag *TAG***  
Prometheus image tag to pull or load. Default: *latest*

**--grafana-tag *TAG***  
Grafana image tag to pull or load. Default: *latest*

**--prom-image *IMAGE***  
Prometheus image name. Default: *docker.io/prom/prometheus*

**--grafana-image *IMAGE***  
Grafana image name. Default: *docker.io/grafana/grafana*

## Container options

**--engine auto\|docker\|podman**  
Force a specific container engine. Default: **auto** (prefers podman if
both are present, as detected by **gsc_detect_engine**).

**--replace**  
Remove any existing container with the same name before starting.

**--keep-container**  
Start containers without **--rm**; they persist after they stop.

**--min-port *N***  
Lowest port number for Prometheus auto-selection. Default: *9090*

**--max-port *N***  
Highest port number for Prometheus auto-selection. Default: *9599*

**--exclude-port *N***  
Exclude an additional port from selection. May be repeated.

## Cleanup options (for --stop)

**--volume**  
Also delete data directories associated with stopped containers.

**--override=y**  
Skip confirmation prompts during cleanup.

## Other options

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
Success.

**1**  
A required argument was missing, a file was not found, an image was not
loaded, no free port was available, or a container failed to start.

# ENVIRONMENT

**GSC_LIB_PATH**  
Override the path to *gsc_core.sh* (default: same directory as the
script).

# FILES

*BUNDLEDIR/airgap_manifest.txt*  
Written by **--save-images** and read by **--load-images**. Records
image references, tar filenames, and digests.

*BUNDLEDIR/prometheus\_\<tag\>.tar*  
Exported Prometheus image tar.

*BUNDLEDIR/grafana\_\<tag\>.tar*  
Exported Grafana image tar.

*BASEDIR/CUSTOMER/SR/prom/data/*  
Extracted Prometheus snapshot data. Mounted as */prometheus* in the
Prometheus container.

*BASEDIR/CUSTOMER/SR/prom/prometheus.yml*  
Minimal Prometheus configuration written by **--start**.

*BASEDIR/CUSTOMER/SR/grafana/dashboards/*  
Dashboard JSON files copied/extracted from **-D** arguments.

*BASEDIR/CUSTOMER/SR/grafana/provisioning/*  
Grafana provisioning YAML for datasource and dashboard provider.

# EXAMPLES

## Export images on a connected host

    sudo gsc_airgap.sh --save-images /mnt/usb/airgap_bundle

## Transport and load on the air-gapped host

    # Copy /mnt/usb/airgap_bundle to the target, then:
    sudo gsc_airgap.sh --load-images /mnt/usb/airgap_bundle

## Start both containers with dashboards

    sudo gsc_airgap.sh --start \
        -c ACME -s 05304447 \
        -f /data/psnap_2026-Jul-04.tar.xz \
        -b /opt/prom_instances \
        -D /data/GrafanaDashboards_2.6.zip

## Start with a pinned image version

    sudo gsc_airgap.sh --save-images /mnt/usb/bundle \
        --prom-tag v2.51.0 --grafana-tag 10.4.3
    sudo gsc_airgap.sh --load-images /mnt/usb/bundle \
        --prom-tag v2.51.0 --grafana-tag 10.4.3
    sudo gsc_airgap.sh --start \
        -c ACME -s 05304447 \
        -f psnap_2026-Jul-04.tar.xz -b /opt/prom \
        --prom-tag v2.51.0 --grafana-tag 10.4.3

## Stop and remove all managed containers

    sudo gsc_airgap.sh --stop --override=y

# SEE ALSO

**gsc_prometheus**(1), **expand_hcpcs_support**(1), **runchk**(1),
**hcpcs-health-check**(7), **docker**(1), **podman**(1)

# AUTHORS

Hitachi Vantara GSC
