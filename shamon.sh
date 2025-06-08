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
# export PATH="/bin:/sbin:/usr/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"
DURATION=5       # Length of each recording in seconds
BASE_INTERVAL=10 # Startinterval in seconden
MAX_INTERVAL=60  # Maximale wachttijd
INTERVAL=$BASE_INTERVAL
RATE=22050                          # Audio sample rate
BITS=16                             # Audio bit depth
DB_FILE="$HOME/.music_monitor.db"   # SQLite database location
LOG_FILE="$HOME/.music_monitor.log" # Log file to write debug output
THRESHOLD=0.01                      # Minimum RMS level to trigger recognition
DEBUG=true                          # Enable debug output by default
INPUT_DEVICE=""
JSON_OUTPUT=false

# ANSI Color codes
GREEN='\033[0;32m'
BLUE='\033[0;34m'
GRAY='\033[0;90m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Enable read for Enter detection
stty -icanon -echo

###########################################
# Helper Functions
###########################################

# Debug logging function
debug_log() {
    if $DEBUG; then
        printf "%s DEBUG: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >>"$LOG_FILE"
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
    stty sane
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

# Prompt user to select audio input device
echo -e "${BLUE}Available audio input devices:${NC}"
input_list=$(sox -V3 -n -t coreaudio dummy trim 0 1 2>&1 | grep 'Found Audio Device' | sed -E 's/.*"(.+)"/\1/')
if [ -z "$input_list" ]; then
    echo -e "${RED}No input devices found.${NC}"
    exit 1
fi

IFS=$'\n' read -rd '' -a inputs <<<"$input_list"

for i in "${!inputs[@]}"; do
    printf "%2d) %s\n" $((i + 1)) "${inputs[$i]}"
done

read -p "Enter the number of the input device to use: " device_number
INPUT_DEVICE="${inputs[$((device_number - 1))]}"
echo -e "${BLUE}Using input device: $INPUT_DEVICE${NC}"

# Set up exit trap
trap cleanup INT TERM

# Check for required dependencies
for cmd in sox vibra jq sqlite3 bc; do
    if ! command -v $cmd &>/dev/null; then
        echo -e "${RED}Error: $cmd is not installed${NC}" >&2
        exit 1
    fi
done

# Initialize SQLite database
sqlite3 "$DB_FILE" "CREATE TABLE IF NOT EXISTS songs (
    timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
    title TEXT,
    artist TEXT,
    audio_level REAL
);"

# Hide cursor for clean output
tput civis
# Start with a fresh log file every run
: >"$LOG_FILE"

# Open the log file in the default viewer (non-blocking)
if command -v open >/dev/null 2>&1; then
    # macOS
    open "$LOG_FILE" &
elif command -v xdg-open >/dev/null 2>&1; then
    # Linux
    xdg-open "$LOG_FILE" >/dev/null 2>&1 &
fi

# Initial console output
if ! $JSON_OUTPUT; then
    clear
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
first_run=false # Ensure we wait even before the first recognition

while true; do
    # Wait between checks (can be skipped with Enter)
    if ! $first_run; then
        if ! $JSON_OUTPUT; then
            for ((i = INTERVAL; i > 0; i--)); do
                clear_line
                printf "${GRAY}Next check in %2ds (press Enter to skip) %s${NC}" "$i" "$(printf '%.*s' $((i % 4)) '...')"

                # Check if Enter is pressed
                read -t 1 -s -r input
                if [[ $? -eq 0 ]]; then
                    clear_line
                    echo -e "${YELLOW}⏩ Skipping wait on user input...${NC}"
                    break
                fi
            done
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
    # Audio Level Detection
    ###########################################

    debug_log "Recording audio level sample..."
    TEMP_AUDIO="/tmp/audio_sample.wav"
    sox -t coreaudio "$INPUT_DEVICE" -b $BITS -e signed-integer -r $RATE -c 1 "$TEMP_AUDIO" trim 0 0.5 2>/dev/null

    # Analyse the recorded audio and extract the level before logging
    audio_stat=$(sox -t wav "$TEMP_AUDIO" -n stat 2>&1)
    audio_level=$(echo "$audio_stat" | awk '/RMS[[:space:]]+amplitude/ {print $3}')
    audio_level=$(echo "$audio_level" | tr ',' '.')

    if [ -z "$audio_level" ]; then
        audio_level=0.0
        debug_log "RMS amplitude not found, defaulting audio level to 0.0"
    fi

    debug_log "Detected RMS audio level: $audio_level"

    if (($(echo "$audio_level < 0.01" | bc -l))); then
        debug_log "Too soft. There's either no music playing or the music is too soft."
        continue
    fi

    ###########################################
    # Song Recognition
    ###########################################

    debug_log "Starting recognition..."

    # Record audio and perform recognition
    result=$(sox -t coreaudio "$INPUT_DEVICE" -t raw -b $BITS -e signed-integer -r $RATE -c 1 - trim 0 $DURATION 2>/dev/null |
        vibra --recognize --seconds $DURATION --rate $RATE --channels 1 --bits $BITS)

    # Validate JSON response
    if echo "$result" | jq -e . >/dev/null 2>&1; then
        debug_log "Valid JSON received"

        # Check if track information exists
        if echo "$result" | jq -e '.track' >/dev/null 2>&1; then
            debug_log "Track information found"

            # Extract song information with trimmed title
            raw_title=$(echo "$result" | jq -r '.track.title')
            artist=$(echo "$result" | jq -r '.track.subtitle')
            title=$(echo "$raw_title" | sed 's/ *(.*//')
            song_info="$title by $artist"
            timestamp=$(date '+%H:%M:%S')

            debug_log "Song detected: $song_info"

            # Only process if it's a different song from last detection
            if [[ "$last_song" != "$song_info" ]]; then
                INTERVAL=$BASE_INTERVAL
                last_song="$song_info"

                if $JSON_OUTPUT; then
                    echo "$result" | jq -c --raw-output \
                        "{timestamp: \"$timestamp\", title: .track.title, artist: .track.subtitle, audio_level: $audio_level}"
                else
                    clear_line
                    echo -e "${GREEN}[$timestamp] $song_info${NC}"
                fi

                debug_log "Storing in database..."
                title_escaped=$(echo "$title" | sed "s/'/''/g")
                artist_escaped=$(echo "$artist" | sed "s/'/''/g")
                sqlite3 "$DB_FILE" "INSERT INTO songs (timestamp, title, artist, audio_level)
                    VALUES (datetime('now', 'localtime'), '$title_escaped', '$artist_escaped', $audio_level);"

            else
                INTERVAL=$((INTERVAL + 5))
                if ((INTERVAL > 30)); then
                    INTERVAL=30
                fi
                debug_log "Same song detected again. Increasing interval to $INTERVAL seconds."
            fi
            consecutive_empty=0

        else
            debug_log "No track information in JSON"
            ((consecutive_empty++))
            INTERVAL=$((BASE_INTERVAL * consecutive_empty))
            if ((INTERVAL > MAX_INTERVAL)); then
                INTERVAL=$MAX_INTERVAL
            fi
        fi
    else
        debug_log "No valid response from recognition"
        ((consecutive_empty++))
        INTERVAL=$((BASE_INTERVAL * consecutive_empty))
        if ((INTERVAL > MAX_INTERVAL)); then
            INTERVAL=$MAX_INTERVAL
        fi
        debug_log "No recognition. Setting next interval to $INTERVAL seconds"
    fi

    # Show "No music detected" after several empty results
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
# Query history:
# sqlite3 ~/.music_monitor.db "SELECT datetime(timestamp, 'localtime'),
#     title, artist FROM songs ORDER BY timestamp DESC LIMIT 10;"
###########################################
