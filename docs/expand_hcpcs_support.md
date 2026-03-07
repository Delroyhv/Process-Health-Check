# NAME

expand_hcpcs_support.sh - expand HCP CS support bundles and generate
Prometheus healthcheck configs

# SYNOPSIS

## Full mode (expand + healthcheck generation)

**expand_hcpcs_support.sh** \[**-r** *dir*\] \[**-f** *archive*\] . . .
\[**--no-healthcheck**\] \[**-o** *version*\] \[**-s** *host*\] \[**-p**
*port*\] \[**-d** *dir*\] \[**-e**\]

## Healthcheck-only mode (update existing healthcheck.conf)

**expand_hcpcs_support.sh** **--healthcheck-only** **-u** \[**-p**
*port*\] \[**-s** *host*\] \[**-o** *version*\] \[**-f** *conf*\]

## Healthcheck-only mode (generate config from a psnap)

**expand_hcpcs_support.sh** **--healthcheck-only** **-P** *psnap.tar.xz*
\[**-p** *port*\] \[**-s** *host*\] \[**-u**\]

# DESCRIPTION

**expand_hcpcs_support.sh** has two operating modes:

## Full mode (default)

Searches *--root-dir* for *supportLogs\_\*.tar.xz* archives and extracts
each one into a timestamped subdirectory. Any *\*Prometheus\*.tar.xz*
files found are renamed to the standard
*psnap_YYYY-Mon-DD_HH-MM-SS.tar.xz* convention. For each psnap a
*healthcheck.conf* is written containing the Prometheus connection
parameters needed by **runchk.sh**.

The HCP CS product version is auto-detected from *setup.json* inside the
extracted archive. Use **-o** to override it.

When more than one psnap resides in the same SupportLog directory the
first uses *healthcheck.conf* and subsequent ones use
*healthcheck.conf-YYYY-MM-DDTHH:MM:SS*.

## Healthcheck-only mode (--healthcheck-only)

No extraction is performed. The mode has two sub-cases:

**With -P *psnap***  
Generates a fresh *healthcheck.conf* for the given psnap file and moves
the psnap into the correct SupportLog directory if it is not already
there. Add **-u** to update an existing config rather than overwriting
it.

**With -u (no -P)**  
Updates the existing *healthcheck.conf* in the current directory (or the
path given with **-f**), changing only the fields explicitly provided on
the command line (**-p**, **-s**, **-o**, **-d**). All other fields are
preserved exactly as written. This is the form used in Step 4 of the
standard workflow.

# OPTIONS

## Core options

**-r**, **--root-dir** *DIR*  
Root directory to search for support log archives. Default: *.*

**--no-healthcheck**  
Unpack support logs but skip *healthcheck.conf* generation for all psnap
files.

**--healthcheck-only**  
Do not unpack anything; only operate on healthcheck configuration.
Requires either **-P** or **-u**.

**-u**, **--update**  
In **--healthcheck-only** mode: update an existing *healthcheck.conf*
instead of overwriting it. Only fields explicitly supplied on the CLI
are changed.

**-P**, **--psnap** *FILE*  
Prometheus snapshot archive to process in **--healthcheck-only** mode.

## Healthcheck options

**-o**, **--os_version** *VER*  
HCP CS version string (e.g. *2.6.0*). Overrides the value auto-detected
from *setup.json* inside the extracted archive.

**-s**, **--prom_server** *HOST*  
Prometheus server hostname or IP address. Default: *127.0.0.1*

**-p**, **--port** *PORT*  
Prometheus server port. Default: *9090*

**-d**, **--dir** *DIR*  
Installation directory for the health check scripts, written into
*healthcheck.conf* as *\_install_dir*. Default: */usr/local/bin/*

**-f**, **--file** *FILE*  
In **full** mode: a specific support log archive to process (may be
repeated to process multiple archives explicitly instead of
auto-discovery).  
In **--healthcheck-only** mode: path to the *healthcheck.conf* file to
create or update. Default: *healthcheck.conf*

## Space-estimation options

**-e**, **--estimate**  
Before extracting, check available free space and warn or abort if
insufficient.

**--estimate-only**  
Print space estimates but do not extract anything.

**--no-space-check**  
Disable free-space checking even when **-e** was specified.

## Other

**-h**, **--help**  
Print a usage summary and exit.

**-V**, **--version**  
Print the script version and exit.

# EXIT STATUS

**0**  
Success.

**1**  
A required argument was missing, a file was not found, or an unexpected
error occurred.

# FILES

*supportLogs\_\*.tar.xz*  
Support log archives discovered and extracted by full mode.

*\*Prometheus\*.tar.xz*  
Prometheus snapshot archives renamed to *psnap\_\*.tar.xz* by full mode.

*psnap_YYYY-Mon-DD_HH-MM-SS.tar.xz*  
Normalised Prometheus snapshot filename.

*healthcheck.conf*  
Generated or updated Prometheus connection parameter file consumed by
**runchk.sh**.

*setup.json*  
Cluster setup file inside the extracted support bundle; used for
automatic HCP CS version detection.

# EXAMPLES

## Expand a full support bundle

    expand_hcpcs_support.sh -r /ci/05304447

## Expand but skip healthcheck generation

    expand_hcpcs_support.sh -r /ci/05304447 --no-healthcheck

## Generate a fresh healthcheck.conf for a specific psnap

    expand_hcpcs_support.sh --healthcheck-only \
        -P psnap_2026-Jul-04_12-53-12.tar.xz -p 9092

## Update only the port in an existing healthcheck.conf (Step 4 of workflow)

    expand_hcpcs_support.sh --healthcheck-only -u -p 9092

## Update port and server address

    expand_hcpcs_support.sh --healthcheck-only -u -p 9092 -s 192.0.2.10

# SEE ALSO

**gsc_prometheus**(1), **runchk**(1), **hcpcs-health-check**(7)

# AUTHORS

Hitachi Vantara GSC
