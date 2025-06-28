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
DEBUG=false                       # Enable debug output by default
JSON_OUTPUT=false                 # Enable JSON output format
AUDIO_THRESHOLD=0.003             # Minimal RMS level for recognition
INPUT_DEVICE=""                   # Selected input device
AUTO_INPUT=false                  # Auto-select input device
HEADLESS=false                    # Run in background

# Preferred audio input devices (in order of preference)
PREFERRED_DEVICES=(
    "C922 Pro Stream Webcam"
    "MacBook Pro Microphone"
)

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
        if ! $JSON_OUTPUT && ! $HEADLESS; then
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
    if ! $HEADLESS; then
        tput cnorm # Restore cursor
    fi
    if ! $JSON_OUTPUT && ! $HEADLESS; then
        total_songs=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM songs")
        echo -e "\n${BLUE}Monitor stopped. Detected $total_songs songs${NC}"
    fi
    debug_log "Cleanup completed"
    exit 0
}

# Function to switch to next available audio device
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
    if ! $device_found && $start_index -gt 0; then
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
    
    debug_log "No alternative preferred device found"
    return 1
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
    --auto-input)
        AUTO_INPUT=true
        debug_log "Auto-input mode enabled"
        ;;
    --headless)
        HEADLESS=true
        debug_log "Headless mode enabled"
        ;;
    *)
        echo "Unknown parameter: $1"
        exit 1
        ;;
    esac
    shift
done

# Get list of available audio input devices
if $HEADLESS; then
    input_list=$(sox -V3 -n -t coreaudio dummy trim 0 1 2>&1 2>/dev/null | grep 'Found Audio Device' | sed -E 's/.*"(.+)"/\1/')
else
    input_list=$(sox -V3 -n -t coreaudio dummy trim 0 1 2>&1 | grep 'Found Audio Device' | sed -E 's/.*"(.+)"/\1/')
fi
if [ -z "$input_list" ]; then
    if ! $HEADLESS; then
        echo -e "${RED}No input devices found.${NC}"
    fi
    exit 1
fi

IFS=$'\n' read -rd '' -a inputs <<<"$input_list"

if $AUTO_INPUT; then
    # Auto-select input device from preferred list
    debug_log "Auto-selecting input device..."
    device_found=false
    
    for i in "${!PREFERRED_DEVICES[@]}"; do
        for available in "${inputs[@]}"; do
            if [[ "$available" == "${PREFERRED_DEVICES[$i]}" ]]; then
                INPUT_DEVICE="${PREFERRED_DEVICES[$i]}"
                current_device_index=$i
                device_found=true
                debug_log "Auto-selected device: $INPUT_DEVICE"
                break 2
            fi
        done
    done
    
    if ! $device_found; then
        if ! $HEADLESS; then
            echo -e "${RED}Error: None of the preferred devices found.${NC}"
            echo -e "${RED}Available devices:${NC}"
            for device in "${inputs[@]}"; do
                echo "  - $device"
            done
            echo -e "${RED}Preferred devices:${NC}"
            for device in "${PREFERRED_DEVICES[@]}"; do
                echo "  - $device"
            done
        fi
        exit 1
    fi
    
    if ! $HEADLESS; then
        echo -e "${BLUE}Auto-selected input device: $INPUT_DEVICE${NC}"
    fi
else
    # Manual device selection
    echo -e "${BLUE}Available audio input devices:${NC}"
    for i in "${!inputs[@]}"; do
        printf "%2d) %s\n" $((i + 1)) "${inputs[$i]}"
    done
    
    read -p "Enter the number of the input device to use: " device_number
    INPUT_DEVICE="${inputs[$((device_number - 1))]}"
    echo -e "${BLUE}Using input device: $INPUT_DEVICE${NC}"
fi

# Set up exit trap
trap cleanup INT TERM

# Check for required dependencies
debug_log "Checking dependencies"
for cmd in sox vibra jq sqlite3; do
    if ! command -v $cmd &>/dev/null; then
        if ! $HEADLESS; then
            echo -e "${RED}Error: $cmd is not installed${NC}" >&2
        fi
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

# Handle headless mode
if $HEADLESS; then
    LOG_FILE="$HOME/.music_monitor_ram.log"
    # Start with a fresh log file
    : >"$LOG_FILE"
    
    # Fork the script to run in background
    if [[ "${SHAMON_BACKGROUND:-}" != "true" ]]; then
        # Parent process
        export SHAMON_BACKGROUND=true
        
        # Create a detached screen session for audio access on macOS
        if command -v screen >/dev/null 2>&1; then
            # Use screen to maintain terminal context for audio
            screen_name="shamon_ram_$$"
            screen -dmS "$screen_name" "$0" "$@"
            
            # Get the PID of the process running in screen
            sleep 1
            bg_pid=$(screen -ls "$screen_name" | grep -oE '[0-9]+\.' | head -1 | tr -d '.')
            
            # Redirect screen output to log file
            screen -S "$screen_name" -X logfile "$LOG_FILE"
            screen -S "$screen_name" -X log on
            
            echo -e "${GREEN}📻 Music Monitor (RAM) started in background mode (screen session)${NC}"
            echo "Screen session: $screen_name"
            echo "Process ID: $bg_pid"
            echo "Log file: $LOG_FILE"
            echo "To view: screen -r $screen_name"
            echo "To stop: screen -S $screen_name -X quit"
        else
            # Fall back to simple background with terminal attached
            # This maintains audio access but won't survive terminal close
            ( export SHAMON_BACKGROUND=true; exec "$0" "$@" >>"$LOG_FILE" 2>&1 ) &
            bg_pid=$!
            disown $bg_pid
            
            echo -e "${GREEN}📻 Music Monitor (RAM) started in background mode${NC}"
            echo "Process ID: $bg_pid"
            echo "Log file: $LOG_FILE"
            echo "To stop: kill $bg_pid"
            echo -e "${YELLOW}Note: Process will stop if you close this terminal${NC}"
        fi
        
        exit 0
    fi
    
    # Child process continues here
    debug_log "Running in headless mode (background process)"
fi

# Hide cursor for clean output (only in interactive mode)
if ! $HEADLESS; then
    tput civis
fi

# Initial console output
if ! $JSON_OUTPUT && ! $HEADLESS; then
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
consecutive_zero_audio=0 # Track consecutive zero audio level readings
max_zero_audio=3 # Switch device after this many consecutive zero readings
current_device_index=-1 # Track which device we're using from preferred list

while true; do
    # Safety check to prevent rapid loops in headless mode
    loop_start_time=$(date +%s)
    
    # Handle intervals between recordings
    if ! $first_run; then
        # In background/headless mode, just sleep without any output
        if $JSON_OUTPUT || $HEADLESS || [[ "${SHAMON_BACKGROUND:-}" == "true" ]]; then
            sleep "$INTERVAL"
        else
            # Interactive countdown for terminal mode
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

    # Create a temporary pipe for audio streaming
    audio_pipe=$(mktemp -u)
    mkfifo "$audio_pipe"
    debug_log "Created named pipe: $audio_pipe"

    # Start recording in background
    sox -t coreaudio "$INPUT_DEVICE" -t raw -b $BITS -e signed-integer -r $RATE -c 1 "$audio_pipe" trim 0 $DURATION 2>/dev/null &
    sox_pid=$!

    # Create a temporary file for the audio level
    level_file=$(mktemp)

    # Read and process the audio data
    audio_data=$(cat "$audio_pipe" | tee >(get_audio_level >"$level_file") | base64)
    wait $sox_pid

    # Get and validate audio level
    audio_level=$(cat "$level_file" 2>/dev/null || echo "0")
    rm -f "$level_file" "$audio_pipe"

    # Validate audio level is a number (including decimals and scientific notation)
    if [[ ! "$audio_level" =~ ^[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$ ]]; then
        audio_level="0"
    fi

    if (($(echo "$audio_level < $AUDIO_THRESHOLD" | bc -l))); then
        debug_log "Audio level too low ($audio_level), skipping recognition"
        
        # Check if audio level is exactly zero (device might be disconnected)
        if (($(echo "$audio_level == 0" | bc -l))); then
            ((consecutive_zero_audio++))
            debug_log "Zero audio level detected (count: $consecutive_zero_audio)"
            
            # Switch device if we've had too many consecutive zero readings
            if ((consecutive_zero_audio >= max_zero_audio)); then
                if switch_audio_device; then
                    consecutive_zero_audio=0
                    # Continue to next iteration with new device
                    continue
                else
                    # No alternative device available, reset counter and continue
                    consecutive_zero_audio=0
                fi
            fi
        else
            # Non-zero but still too low, reset zero counter
            consecutive_zero_audio=0
        fi
        
        continue
    fi
    
    # Audio level is good, reset zero counter
    consecutive_zero_audio=0

    ###########################################
    # Song Recognition
    ###########################################

    if [[ "${SHAMON_BACKGROUND:-}" == "true" ]]; then
        # In background mode, suppress vibra stderr
        result=$(echo "$audio_data" | base64 -d | vibra --recognize --seconds $DURATION --rate $RATE --channels 1 --bits $BITS 2>/dev/null)
    else
        # In interactive mode, allow vibra stderr for debugging
        result=$(echo "$audio_data" | base64 -d | vibra --recognize --seconds $DURATION --rate $RATE --channels 1 --bits $BITS)
    fi

    # Process recognition results
    if echo "$result" | jq -e . >/dev/null 2>&1; then
        if echo "$result" | jq -e '.track' >/dev/null 2>&1; then

            # Extract song information
            song_info=$(echo "$result" | jq -r '.track | "\(.title) by \(.subtitle)"')
            title=$(echo "$result" | jq -r '.track.title')
            artist=$(echo "$result" | jq -r '.track.subtitle')
            timestamp=$(date '+%H:%M:%S')

            if [[ "$last_song" != "$song_info" ]]; then
                if $JSON_OUTPUT; then
                    echo "$result" | jq -c --raw-output \
                        "{timestamp: \"$timestamp\", title: .track.title, artist: .track.subtitle, audio_level: $audio_level}"
                elif ! $HEADLESS && [[ "${SHAMON_BACKGROUND:-}" != "true" ]]; then
                    clear_line
                    echo -e "${GREEN}[$timestamp] $song_info${NC}"
                else
                    # In headless/background mode, log to debug log
                    debug_log "[$timestamp] $song_info"
                fi

                # Store in SQLite database
                title_escaped=$(echo "$title" | sed "s/'/''/g")
                artist_escaped=$(echo "$artist" | sed "s/'/''/g")
                sqlite3 "$DB_FILE" "INSERT INTO songs (timestamp, title, artist, audio_level)
                    VALUES (datetime('now', 'localtime'), '$title_escaped', '$artist_escaped', $audio_level);"

                last_song="$song_info"
                consecutive_empty=0
            fi
        else
            ((consecutive_empty++))
        fi
    else
        ((consecutive_empty++))
    fi

    if ((consecutive_empty >= max_retries)) && ! $JSON_OUTPUT && ! $HEADLESS && [[ "${SHAMON_BACKGROUND:-}" != "true" ]]; then
        clear_line
        echo -ne "${GRAY}No music detected${NC}"
        consecutive_empty=0
    fi
    
    # Safety check: ensure minimum loop time in headless mode
    if $HEADLESS; then
        loop_end_time=$(date +%s)
        loop_duration=$((loop_end_time - loop_start_time))
        if ((loop_duration < 5)); then
            safety_sleep=$((5 - loop_duration))
            sleep $safety_sleep
        fi
    fi
done

###########################################
# Usage:
# ./script.sh              # Normal mode with debug info
# ./script.sh --json       # JSON output mode
# ./script.sh --debug      # Debug mode
# ./script.sh --auto-input # Auto-select input device from preferred list
# ./script.sh --headless   # Run in background without console output
#
# Database Query Example:
# sqlite3 ~/.music_monitor.db "SELECT datetime(timestamp, 'localtime'),
#     title, artist FROM songs ORDER BY timestamp DESC LIMIT 10;"
###########################################
