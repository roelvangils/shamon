#!/bin/bash

###########################################
# Shamon Common Functions Library
#
# This file contains shared functions used across multiple Shamon scripts.
# Source this file in your scripts with: source "$(dirname "$0")/common.sh"
###########################################

# ANSI Color codes
GREEN='\033[0;32m'
BLUE='\033[0;34m'
GRAY='\033[0;90m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Network check caching (reduces DNS queries)
LAST_NETWORK_CHECK=0
NETWORK_CACHE_DURATION=30

###########################################
# Debug logging function
# Prints debug messages with timestamp if DEBUG is enabled
# Arguments:
#   $1 - Message to log
###########################################
debug_log() {
    if $DEBUG; then
        printf "%s DEBUG: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >>"$LOG_FILE"
    fi
}

###########################################
# Clear current line in terminal
# Used for clean output formatting
###########################################
clear_line() {
    echo -ne "\r\033[K"
}

###########################################
# Network connectivity check
# Uses caching to reduce unnecessary ping requests
# Returns: 0 if network is available, 1 otherwise
###########################################
check_network() {
    local now
    now=$(date +%s)

    # Use cached result if within cache duration
    if ((now - LAST_NETWORK_CHECK < NETWORK_CACHE_DURATION)); then
        return 0
    fi

    if ! ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
        if ! $JSON_OUTPUT && ! $HEADLESS; then
            clear_line
            echo -ne "${RED}Network unavailable, waiting...${NC}"
        fi
        debug_log "Network unavailable"
        LAST_NETWORK_CHECK=0  # Reset cache on failure
        return 1
    fi

    LAST_NETWORK_CHECK=$now
    return 0
}

###########################################
# Switch to next available audio device
# Attempts to switch to the next preferred device when current device fails
# Returns: 0 if switch successful, 1 otherwise
###########################################
switch_audio_device() {
    debug_log "Attempting to switch audio device due to zero audio levels"

    # Get current list of available devices
    local new_input_list
    if $HEADLESS; then
        new_input_list=$(sox -V3 -n -t coreaudio dummy trim 0 1 2>&1 2>/dev/null | grep 'Found Audio Device' | sed -E 's/.*"(.+)"/\1/')
    else
        new_input_list=$(sox -V3 -n -t coreaudio dummy trim 0 1 2>&1 | grep 'Found Audio Device' | sed -E 's/.*"(.+)"/\1/')
    fi

    if [ -z "$new_input_list" ]; then
        debug_log "No audio devices found during switch attempt"
        return 1
    fi

    IFS=$'\n' read -rd '' -a available_devices <<<"$new_input_list"

    # Try to find next preferred device
    local device_found=false
    local start_index=$((current_device_index + 1))

    for ((i = start_index; i < ${#PREFERRED_DEVICES[@]}; i++)); do
        for available in "${available_devices[@]}"; do
            if [[ "$available" == "${PREFERRED_DEVICES[$i]}" ]]; then
                INPUT_DEVICE="${PREFERRED_DEVICES[$i]}"
                current_device_index=$i
                device_found=true
                debug_log "Switched to device: $INPUT_DEVICE"
                if ! $HEADLESS && ! $JSON_OUTPUT && [[ "${SHAMON_BACKGROUND:-}" != "true" ]]; then
                    echo -e "\n${YELLOW}Audio device switched to: $INPUT_DEVICE${NC}"
                fi
                return 0
            fi
        done
    done

    # If no more preferred devices, try from beginning
    if ! $device_found && ((start_index > 0)); then
        for ((i = 0; i < start_index; i++)); do
            for available in "${available_devices[@]}"; do
                if [[ "$available" == "${PREFERRED_DEVICES[$i]}" ]]; then
                    INPUT_DEVICE="${PREFERRED_DEVICES[$i]}"
                    current_device_index=$i
                    device_found=true
                    debug_log "Switched to device (wrapped): $INPUT_DEVICE"
                    if ! $HEADLESS && ! $JSON_OUTPUT && [[ "${SHAMON_BACKGROUND:-}" != "true" ]]; then
                        echo -e "\n${YELLOW}Audio device switched to: $INPUT_DEVICE${NC}"
                    fi
                    return 0
                fi
            done
        done
    fi

    # Last resort: try first available device that isn't the current one
    if ! $device_found; then
        for available in "${available_devices[@]}"; do
            if [[ "$available" != "$INPUT_DEVICE" ]]; then
                INPUT_DEVICE="$available"
                current_device_index=-1  # Reset index since not a preferred device
                debug_log "Falling back to available device: $INPUT_DEVICE"
                if ! $HEADLESS && ! $JSON_OUTPUT && [[ "${SHAMON_BACKGROUND:-}" != "true" ]]; then
                    echo -e "\n${YELLOW}Audio device switched to: $INPUT_DEVICE${NC}"
                fi
                return 0
            fi
        done
    fi

    debug_log "No alternative device found"
    return 1
}

###########################################
# Get installation command for a package
# Arguments:
#   $1 - Package name
# Returns: Installation command string
###########################################
get_install_command() {
    local pkg=$1
    if command -v brew &>/dev/null; then
        echo "brew install $pkg"
    elif command -v apt-get &>/dev/null; then
        echo "sudo apt-get install $pkg"
    elif command -v yum &>/dev/null; then
        echo "sudo yum install $pkg"
    else
        echo "Please install $pkg manually"
    fi
}

###########################################
# Safely escape SQL string values
# Arguments:
#   $1 - String to escape
# Returns: Escaped string suitable for SQL
###########################################
sql_escape() {
    printf '%s' "$1" | sed "s/'/''/g"
}
