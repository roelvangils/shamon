#!/bin/bash

###########################################
# Music Recognition Monitor
#
# This script continuously monitors audio input and identifies playing songs
# using the Vibra audio recognition service. It stores results in a SQLite
# database and provides real-time feedback.
#
# Features:
# - Continuous audio monitoring
# - SQLite database storage
# - Network connectivity checks
# - Debug mode
# - JSON output option
# - Audio level detection
# - Colored console output
###########################################

# Configuration
DURATION=5                        # Length of each recording in seconds
INTERVAL=15                       # Wait time between recordings in seconds
RATE=22050                        # Audio sample rate
BITS=16                           # Audio bit depth
DB_FILE="$HOME/.music_monitor.db" # SQLite database location
DEBUG=true                        # Enable debug output by default
JSON_OUTPUT=false
AUDIO_THRESHOLD=0.005 # Updated minimal RMS level for recognition

# ANSI Color codes
GREEN='\033[0;32m'
BLUE='\033[0;34m'
GRAY='\033[0;90m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

###########################################
# Helper Functions
###########################################

# Debug logging function
debug_log() {
    if $DEBUG; then
        clear_line
        echo -e "${YELLOW}DEBUG: $1${NC}"
    fi
}

# Clear current line in terminal
clear_line() {
    echo -ne "\r\033[K"
}

# Network connectivity check
check_network() {
    if ! ping -c 1 8.8.8.8 >/dev/null 2>&1; then
        if ! $JSON_OUTPUT; then
            clear_line
            echo -ne "${RED}Network unavailable, waiting...${NC}"
        fi
        return 1
    fi
    return 0
}

# Cleanup function for graceful exit
cleanup() {
    tput cnorm # Restore cursor
    if ! $JSON_OUTPUT; then
        total_songs=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM songs")
        echo -e "\n${BLUE}Monitor stopped. Detected $total_songs songs${NC}"
    fi
    exit 0
}

###########################################
# Initialization
###########################################

# Parse command line arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
    --json) JSON_OUTPUT=true ;;
    --debug) DEBUG=true ;;
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
for cmd in sox vibra jq sqlite3; do
    if ! command -v $cmd &>/dev/null; then
        echo -e "${RED}Error: $cmd is not installed${NC}" >&2
        exit 1
    fi
done

# Check available audio devices
debug_log "Checking available audio devices..."
sox --help | grep -A 20 'AUDIO DEVICE DRIVERS'

# Initialize SQLite database
sqlite3 "$DB_FILE" "CREATE TABLE IF NOT EXISTS songs (
    timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
    title TEXT,
    artist TEXT,
    audio_level REAL
);"

# Hide cursor for clean output
tput civis

# Initial console output
if ! $JSON_OUTPUT; then
    echo -e "${GREEN}📻 Music Monitor Started${NC} (Press Ctrl+C to stop)"
    echo "Recording ${DURATION}s samples every ${INTERVAL}s"
fi

###########################################
# Main Loop
###########################################

# Initialize variables
last_song=""
consecutive_empty=0
max_retries=3
first_run=true # Flag to skip initial wait

while true; do
    # Skip initial wait on first run, then wait between subsequent checks
    if ! $first_run; then
        if ! $JSON_OUTPUT; then
            accelerate=false
            for ((i = INTERVAL; i > 0; i--)); do
                clear_line
                printf "${GRAY}Next check in %2ds %s (press Enter to start immediately)${NC}" $i "$(printf '%.*s' $((i % 4)) '...')"
                # Wait 1 second, break early if Enter is pressed
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

    # Check network connectivity before proceeding
    if ! check_network; then
        sleep 30
        continue
    fi

    ###########################################
    # Audio Level Detection and Recording
    ###########################################

    debug_log "Recording audio sample..."
    audio_file=$(mktemp)
    audio_device="default" # Explicit Core Audio device on macOS
    sox -t coreaudio "$audio_device" -t raw -b $BITS -e signed-integer -r $RATE -c 1 - trim 0 $DURATION >"$audio_file" 2>/dev/null
    sox_exit_code=$?

    if [ $sox_exit_code -ne 0 ]; then
        debug_log "Error capturing audio: sox exited with code $sox_exit_code"
        audio_level=0
    else
        file_size=$(stat -f%z "$audio_file")
        debug_log "Captured audio file size: $file_size bytes"
        # Use explicit raw parameters for proper RMS extraction.
        audio_stats=$(sox -t raw -b $BITS -r $RATE -e signed-integer -c 1 "$audio_file" -n stat 2>&1)
        audio_level=$(echo "$audio_stats" | tr -s ' ' | grep -i 'rms amplitude' | cut -d':' -f2 | sed 's/^ *//')
        if [ -z "$audio_level" ]; then
            audio_level=0
            debug_log "No audio level detected, defaulting to 0"
        else
            debug_log "Audio level detected: $audio_level"
        fi
    fi

    debug_log "Audio sample recorded from file: $audio_file"
    debug_log "AUDIO_THRESHOLD set to: $AUDIO_THRESHOLD"

    if (($(echo "$audio_level < $AUDIO_THRESHOLD" | bc -l))); then
        debug_log "Audio level ($audio_level) below threshold, skipping recognition"
        rm "$audio_file"
        continue
    fi

    ###########################################
    # Song Recognition
    ###########################################

    debug_log "Starting recognition..."
    result=$(cat "$audio_file" | vibra --recognize --seconds $DURATION --rate $RATE --channels 1 --bits $BITS 2>/dev/null)
    debug_log "Raw recognition result received"

    # Validate JSON response
    if echo "$result" | jq -e . >/dev/null 2>&1; then
        debug_log "Valid JSON received"

        # Check if track information exists
        if echo "$result" | jq -e '.track' >/dev/null 2>&1; then
            debug_log "Track information found"

            # Extract song information
            song_info=$(echo "$result" | jq -r '.track | "\(.title) by \(.subtitle)"')
            title=$(echo "$result" | jq -r '.track.title')
            artist=$(echo "$result" | jq -r '.track.subtitle')
            timestamp=$(date '+%H:%M:%S')

            debug_log "Song detected: $song_info"

            # Only process if it's a different song from last detection
            if [[ "$last_song" != "$song_info" ]]; then
                if $JSON_OUTPUT; then
                    # Output JSON format
                    echo "$result" | jq -c --raw-output \
                        "{timestamp: \"$timestamp\", title: .track.title, artist: .track.subtitle, audio_level: $audio_level}"
                else
                    # Output human-readable format
                    clear_line
                    echo -e "${GREEN}[$timestamp] $song_info${NC}"
                fi

                # Store in SQLite database
                debug_log "Storing in database..."
                # Escape single quotes in title and artist for SQL
                title_escaped=$(echo "$title" | sed "s/'/''/g")
                artist_escaped=$(echo "$artist" | sed "s/'/''/g")
                sqlite3 "$DB_FILE" "INSERT INTO songs (timestamp, title, artist, audio_level)
                    VALUES (datetime('now', 'localtime'), '$title_escaped', '$artist_escaped', $audio_level);"

                last_song="$song_info"
                consecutive_empty=0
            else
                debug_log "Same song as last detection, skipping"
            fi
        else
            debug_log "No track information in JSON"
            ((consecutive_empty++))
        fi
    else
        debug_log "No valid response from recognition"
        ((consecutive_empty++))
    fi

    # Show "No music detected" after several empty results
    if ((consecutive_empty >= max_retries)) && ! $JSON_OUTPUT; then
        clear_line
        echo -ne "${GRAY}No music detected${NC}"
        consecutive_empty=0
    fi

    # Clean up temporary audio file
    rm "$audio_file"
done

###########################################
# Usage:
# ./script.sh              # Normal mode with debug info
# ./script.sh --json       # JSON output mode
# ./script.sh --debug      # Debug mode
#
# Query history:
# sqlite3 ~/.music_monitor.db "SELECT datetime(timestamp, 'localtime'),
#     title, artist FROM songs ORDER BY timestamp DESC LIMIT 10;"
###########################################
