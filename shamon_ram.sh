#!/bin/bash

###########################################
# Music Recognition Monitor
#
# This script continuously monitors audio input and identifies playing songs
# using the Vibra audio recognition service. All audio processing is done
# in memory without writing to temporary files (except for named pipes).
#
# Features:
# - In-memory audio processing
# - Continuous audio monitoring
# - SQLite database storage
# - Network connectivity checks
# - Debug mode
# - JSON output option
# - Audio level detection
# - Colored console output
###########################################

###########################################
# Color Configuration
# These ANSI codes are used for colored output
###########################################
GREEN='\033[0;32m'
BLUE='\033[0;34m'
GRAY='\033[0;90m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

###########################################
# Script Configuration
# Adjust these values to modify the script's behavior
###########################################
DURATION=5                        # Length of each recording in seconds
INTERVAL=15                       # Wait time between recordings in seconds
RATE=22050                        # Audio sample rate
BITS=16                           # Audio bit depth
DB_FILE="$HOME/.music_monitor.db" # SQLite database location
DEBUG=true                        # Enable debug output by default
JSON_OUTPUT=false                 # Enable JSON output format
AUDIO_THRESHOLD=0.003             # Minimal RMS level for recognition

###########################################
# Helper Functions
# Core utility functions used throughout the script
###########################################

# Debug logging function
# Prints debug messages if DEBUG is enabled
debug_log() {
    if $DEBUG; then
        clear_line
        echo -e "${YELLOW}DEBUG: $1${NC}" >&2
    fi
}

# Clear current line in terminal
# Used for clean output formatting
clear_line() {
    echo -ne "\r\033[K"
}

# Network connectivity check
# Returns 0 if network is available, 1 otherwise
check_network() {
    debug_log "Checking network connectivity..."
    if ! ping -c 1 8.8.8.8 >/dev/null 2>&1; then
        if ! $JSON_OUTPUT; then
            clear_line
            echo -ne "${RED}Network unavailable, waiting...${NC}"
        fi
        debug_log "Network check failed"
        return 1
    fi
    debug_log "Network check passed"
    return 0
}

# Process audio and return RMS level
# Analyzes raw audio data and returns the RMS amplitude
get_audio_level() {
    debug_log "Calculating RMS level from audio stream"
    sox -t raw -b $BITS -r $RATE -e signed-integer -c 1 - -n stat 2>&1 | awk '/^RMS.*amplitude/ {gsub(/^[ \t]+|[ \t]+$/,"",$3); print ($3 == "-inf" ? "0" : $3)}'
}

# Cleanup function for graceful exit
# Handles script termination and displays summary
cleanup() {
    debug_log "Cleanup initiated"
    tput cnorm # Restore cursor
    if ! $JSON_OUTPUT; then
        total_songs=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM songs")
        echo -e "\n${BLUE}Monitor stopped. Detected $total_songs songs${NC}"
    fi
    debug_log "Cleanup completed"
    exit 0
}

###########################################
# Initialization
# Script startup and environment setup
###########################################

# Parse command line arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
    --json)
        JSON_OUTPUT=true
        debug_log "JSON output mode enabled"
        ;;
    --debug)
        DEBUG=true
        debug_log "Debug mode enabled"
        ;;
    *)
        echo "Unknown parameter: $1"
        exit 1
        ;;
    esac
    shift
done

# Set up exit trap
trap cleanup INT TERM

# Check for required dependencies
debug_log "Checking dependencies"
for cmd in sox vibra jq sqlite3; do
    if ! command -v $cmd &>/dev/null; then
        echo -e "${RED}Error: $cmd is not installed${NC}" >&2
        exit 1
    fi
done
debug_log "All dependencies found"

# Initialize SQLite database
debug_log "Initializing database at $DB_FILE"
sqlite3 "$DB_FILE" "CREATE TABLE IF NOT EXISTS songs (
    timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
    title TEXT,
    artist TEXT,
    audio_level REAL
);"
debug_log "Database initialization complete"

# Hide cursor for clean output
tput civis

# Initial console output
if ! $JSON_OUTPUT; then
    echo -e "${GREEN}📻 Music Monitor Started${NC} (Press Ctrl+C to stop)"
    echo "Recording ${DURATION}s samples every ${INTERVAL}s"
fi

###########################################
# Main Loop
# Core functionality of the script
###########################################

# Initialize variables
last_song=""
consecutive_empty=0
max_retries=3
first_run=true

while true; do
    # Handle intervals between recordings
    if ! $first_run; then
        if ! $JSON_OUTPUT; then
            accelerate=false
            for ((i = INTERVAL; i > 0; i--)); do
                clear_line
                printf "${GRAY}Next check in %2ds %s (press Enter to start immediately)${NC}" $i "$(printf '%.*s' $((i % 4)) '...')"
                if read -t 1 -n 1 key; then
                    accelerate=true
                    break
                fi
            done
            if $accelerate; then
                clear_line
                echo -e "${GRAY}Starting immediately...${NC}"
            fi
        else
            sleep "$INTERVAL"
        fi
    fi
    first_run=false

    # Network connectivity check
    if ! check_network; then
        sleep 30
        continue
    fi

    ###########################################
    # Audio Capture and Processing
    ###########################################

    debug_log "Starting audio capture"

    # Create a temporary pipe for audio streaming
    audio_pipe=$(mktemp -u)
    mkfifo "$audio_pipe"
    debug_log "Created named pipe: $audio_pipe"

    # Start recording in background
    debug_log "Initiating audio recording"
    sox -t coreaudio "default" -t raw -b $BITS -e signed-integer -r $RATE -c 1 "$audio_pipe" trim 0 $DURATION 2>/dev/null &
    sox_pid=$!

    # Create a temporary file for the audio level
    level_file=$(mktemp)

    # Read and process the audio data
    debug_log "Processing audio stream"
    audio_data=$(cat "$audio_pipe" | tee >(get_audio_level >"$level_file") | base64)
    wait $sox_pid

    # Get and validate audio level
    audio_level=$(cat "$level_file" 2>/dev/null || echo "0")
    rm -f "$level_file" "$audio_pipe"

    debug_log "Raw audio level value: $audio_level"

    # Validate audio level is a number (including decimals and scientific notation)
    if [[ "$audio_level" =~ ^[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$ ]]; then
        debug_log "Valid audio level detected: $audio_level"
    else
        debug_log "Invalid audio level detected, setting to 0"
        audio_level="0"
    fi

    debug_log "Final audio level detected: $audio_level"
    debug_log "Audio data size (base64): $(echo "$audio_data" | wc -c) bytes"

    if (($(echo "$audio_level < $AUDIO_THRESHOLD" | bc -l))); then
        debug_log "Audio level ($audio_level) below threshold ($AUDIO_THRESHOLD), skipping recognition"
        continue
    fi

    ###########################################
    # Song Recognition
    ###########################################

    debug_log "Starting song recognition"
    result=$(echo "$audio_data" | base64 -d | vibra --recognize --seconds $DURATION --rate $RATE --channels 1 --bits $BITS 2>/dev/null)
    debug_log "Recognition result received (${#result} bytes)"

    # Process recognition results
    if echo "$result" | jq -e . >/dev/null 2>&1; then
        debug_log "Valid JSON response received"

        if echo "$result" | jq -e '.track' >/dev/null 2>&1; then
            debug_log "Track information found in response"

            # Extract song information
            song_info=$(echo "$result" | jq -r '.track | "\(.title) by \(.subtitle)"')
            title=$(echo "$result" | jq -r '.track.title')
            artist=$(echo "$result" | jq -r '.track.subtitle')
            timestamp=$(date '+%H:%M:%S')

            debug_log "Song detected: $song_info"

            if [[ "$last_song" != "$song_info" ]]; then
                if $JSON_OUTPUT; then
                    echo "$result" | jq -c --raw-output \
                        "{timestamp: \"$timestamp\", title: .track.title, artist: .track.subtitle, audio_level: $audio_level}"
                else
                    clear_line
                    echo -e "${GREEN}[$timestamp] $song_info${NC}"
                fi

                # Store in SQLite database
                debug_log "Storing song in database"
                title_escaped=$(echo "$title" | sed "s/'/''/g")
                artist_escaped=$(echo "$artist" | sed "s/'/''/g")
                sqlite3 "$DB_FILE" "INSERT INTO songs (timestamp, title, artist, audio_level)
                    VALUES (datetime('now', 'localtime'), '$title_escaped', '$artist_escaped', $audio_level);"
                debug_log "Database update complete"

                last_song="$song_info"
                consecutive_empty=0
            else
                debug_log "Duplicate song detected, skipping"
            fi
        else
            debug_log "No track information in response"
            ((consecutive_empty++))
        fi
    else
        debug_log "Invalid or empty recognition response"
        ((consecutive_empty++))
    fi

    if ((consecutive_empty >= max_retries)) && ! $JSON_OUTPUT; then
        clear_line
        echo -ne "${GRAY}No music detected${NC}"
        consecutive_empty=0
    fi
done

###########################################
# Usage:
# ./script.sh              # Normal mode with debug info
# ./script.sh --json       # JSON output mode
# ./script.sh --debug      # Debug mode
#
# Database Query Example:
# sqlite3 ~/.music_monitor.db "SELECT datetime(timestamp, 'localtime'),
#     title, artist FROM songs ORDER BY timestamp DESC LIMIT 10;"
###########################################
