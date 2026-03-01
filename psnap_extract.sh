#!/bin/bash

# Function to extract archive based on its extension
extract_archive() {
    case "$1" in
        *.tar.gz|*.tgz) tar -xvzf "$1" ;;
        *.tar.xz|*.txz) tar -xvJf "$1" ;;
        *.zip) unzip "$1" ;;
        *) echo "Unsupported file: $1" ;;
    esac
}

# Export the function for use in subshells
export -f extract_archive

# Find and extract archives in all subdirectories
find . -type f \( -name "psnap_*.tgz" -o -name "psnap_*.tar.gz" -o -name "psnap_*.txz" -o -name "psnap_*.tar.xz" -o -name "psnap_*.zip" \) -exec bash -c 'extract_archive "$0"' {} \;

