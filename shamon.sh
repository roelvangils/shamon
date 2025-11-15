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
# - Automatic device switching
###########################################

VERSION="1.2.1"

# Source common functions library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

###########################################
# Configuration
###########################################

# Default configuration
DURATION=5                           # Length of each recording in seconds
BASE_INTERVAL=10                     # Start interval in seconds
MAX_INTERVAL=60                      # Maximum wait time in seconds
INTERVAL=$BASE_INTERVAL
INTERVAL_INCREMENT=5                 # Increment when same song detected
SAME_SONG_MAX_INTERVAL=30            # Max interval for same song
RATE=22050                           # Audio sample rate
BITS=16                              # Audio bit depth
DB_FILE="$HOME/.music_monitor.db"    # SQLite database location
LOG_FILE="$HOME/.music_monitor.log"  # Log file for debug output
AUDIO_THRESHOLD=0.01                 # Minimum RMS level to trigger recognition
DEBUG=false                          # Enable debug output
INPUT_DEVICE=""                      # Selected audio device
JSON_OUTPUT=false                    # JSON output format
AUTO_INPUT=false                     # Auto-select input device
HEADLESS=false                       # Run in background
TEMP_AUDIO="/tmp/shamon_audio_$$.wav" # Temporary audio file

# Preferred audio input devices (in order of preference)
PREFERRED_DEVICES=(
    "C922 Pro Stream Webcam"
    "MacBook Pro Microphone"
)

# Load user configuration if it exists
CONFIG_FILE="$HOME/.shamonrc"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

# Constants for device switching
MAX_CONSECUTIVE_ZERO_AUDIO=3        # Switch device after this many zero readings
MAX_RECOGNITION_RETRIES=3           # Show "no music" message after this many failures

###########################################
# Helper Functions
###########################################

# Show version information
show_version() {
    echo "Shamon v$VERSION"
    echo "Audio monitoring and music recognition tool"
}

# Show help information
show_help() {
    cat <<EOF
Shamon v$VERSION - Music Recognition Monitor

Usage: $0 [OPTIONS]

Options:
    --json          Output in JSON format
    --debug         Enable debug logging to $LOG_FILE
    --auto-input    Auto-select input device from preferred list
    --headless      Run in background without console output
    --version       Show version information
    --help          Show this help message

Examples:
    $0                              # Interactive mode
    $0 --auto-input                 # Auto-select device
    $0 --auto-input --headless      # Background mode
    $0 --json                       # JSON output mode

Configuration:
    Create ~/.shamonrc to customize settings. Example:

    PREFERRED_DEVICES=(
        "My Webcam"
        "Built-in Microphone"
    )
    AUDIO_THRESHOLD=0.005
    BASE_INTERVAL=15

Database:
    Songs are stored in: $DB_FILE
    Query example:
    sqlite3 ~/.music_monitor.db "SELECT * FROM songs ORDER BY timestamp DESC LIMIT 10;"

EOF
}

# Cleanup function for graceful exit
cleanup() {
    debug_log "Cleanup initiated"

    # Clean up temporary files
    rm -f "$TEMP_AUDIO"

    # Restore terminal state
    if ! $HEADLESS && [ -n "$ORIGINAL_STTY" ]; then
        stty "$ORIGINAL_STTY" 2>/dev/null
        tput cnorm 2>/dev/null
        stty sane 2>/dev/null
    fi

    if ! $JSON_OUTPUT && ! $HEADLESS; then
        total_songs=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM songs" 2>/dev/null || echo "0")
        echo -e "\n${BLUE}Monitor stopped. Detected $total_songs songs${NC}"
    fi

    debug_log "Cleanup completed"
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
    --auto-input) AUTO_INPUT=true ;;
    --headless) HEADLESS=true ;;
    --version)
        show_version
        exit 0
        ;;
    --help)
        show_help
        exit 0
        ;;
    *)
        echo "Unknown parameter: $1"
        echo "Use --help for usage information"
        exit 1
        ;;
    esac
    shift
done

# Set up exit trap
trap cleanup INT TERM EXIT

# Store original terminal settings for restoration
if ! $HEADLESS; then
    ORIGINAL_STTY=$(stty -g 2>/dev/null)
fi

# Check for required dependencies
for cmd in sox vibra jq sqlite3 bc; do
    if ! command -v $cmd &>/dev/null; then
        if ! $HEADLESS; then
            echo -e "${RED}Error: $cmd is not installed${NC}" >&2
            echo "Install with: $(get_install_command $cmd)"
        fi
        exit 1
    fi
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
        echo "Please check your audio device connections."
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
            echo -e "${RED}Preferred devices (configure in ~/.shamonrc):${NC}"
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

    while true; do
        read -p "Enter the number of the input device to use (1-${#inputs[@]}): " device_number

        # Validate input
        if [[ "$device_number" =~ ^[0-9]+$ ]] && [ "$device_number" -ge 1 ] && [ "$device_number" -le "${#inputs[@]}" ]; then
            INPUT_DEVICE="${inputs[$((device_number - 1))]}"
            echo -e "${BLUE}Using input device: $INPUT_DEVICE${NC}"
            break
        else
            echo -e "${RED}Invalid selection. Please enter a number between 1 and ${#inputs[@]}${NC}"
        fi
    done
fi

# Initialize SQLite database
sqlite3 "$DB_FILE" "CREATE TABLE IF NOT EXISTS songs (
    timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
    title TEXT,
    artist TEXT,
    audio_level REAL
);"

# Handle headless mode
if $HEADLESS; then
    # Start with a fresh log file
    : >"$LOG_FILE"

    # Fork the script to run in background
    if [[ "${SHAMON_BACKGROUND:-}" != "true" ]]; then
        # Parent process
        export SHAMON_BACKGROUND=true

        # Create a detached screen session for audio access on macOS
        if command -v screen >/dev/null 2>&1; then
            # Use screen to maintain terminal context for audio
            screen_name="shamon_$$"
            screen -dmS "$screen_name" "$0" "$@"

            # Get the PID of the process running in screen
            sleep 1
            bg_pid=$(screen -ls "$screen_name" | grep -oE '[0-9]+\.' | head -1 | tr -d '.')

            # Redirect screen output to log file
            screen -S "$screen_name" -X logfile "$LOG_FILE"
            screen -S "$screen_name" -X log on

            echo -e "${GREEN}📻 Music Monitor started in background mode (screen session)${NC}"
            echo "Screen session: $screen_name"
            echo "Process ID: $bg_pid"
            echo "Log file: $LOG_FILE"
            echo "To view: screen -r $screen_name"
            echo "To stop: screen -S $screen_name -X quit"
        else
            # Fall back to simple background with terminal attached
            # This maintains audio access but won't survive terminal close
            (
                export SHAMON_BACKGROUND=true
                exec "$0" "$@" >>"$LOG_FILE" 2>&1
            ) &
            bg_pid=$!
            disown $bg_pid

            echo -e "${GREEN}📻 Music Monitor started in background mode${NC}"
            echo "Process ID: $bg_pid"
            echo "Log file: $LOG_FILE"
            echo "To stop: kill $bg_pid"
            echo -e "${YELLOW}Note: Process will stop if you close this terminal${NC}"
            echo -e "${YELLOW}Install 'screen' for better background support: $(get_install_command screen)${NC}"
        fi

        exit 0
    fi

    # Child process continues here
    debug_log "Running in headless mode (background process)"
fi

# Non-headless mode setup
if ! $HEADLESS; then
    # Enable read for Enter detection
    stty -icanon -echo 2>/dev/null
    # Hide cursor for clean output
    tput civis 2>/dev/null
fi

# Start with a fresh log file every run (if not already done in headless mode)
if ! $HEADLESS; then
    : >"$LOG_FILE"
fi

# Open the log file in the default viewer (non-blocking)
if ! $HEADLESS && command -v open >/dev/null 2>&1; then
    # macOS
    open "$LOG_FILE" &
elif ! $HEADLESS && command -v xdg-open >/dev/null 2>&1; then
    # Linux
    xdg-open "$LOG_FILE" >/dev/null 2>&1 &
fi

# Initial console output
if ! $JSON_OUTPUT && ! $HEADLESS; then
    clear
    echo -e "${GREEN}📻 Music Monitor Started v$VERSION${NC} (Press Ctrl+C to stop)"
    echo "Recording ${DURATION}s samples every ${INTERVAL}s"
fi

###########################################
# Main Loop
###########################################

# Initialize variables
last_song=""
consecutive_empty=0
first_run=true
consecutive_zero_audio=0
current_device_index=-1

while true; do
    # Safety check to prevent rapid loops in headless mode
    loop_start_time=$(date +%s)

    # Wait between checks (can be skipped with Enter)
    if ! $first_run; then
        # In background/headless mode, just sleep without any output
        if $JSON_OUTPUT || $HEADLESS || [[ "${SHAMON_BACKGROUND:-}" == "true" ]]; then
            sleep "$INTERVAL"
        else
            # Interactive countdown for terminal mode
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

    # Record a short sample for level detection
    sox -t coreaudio "$INPUT_DEVICE" -b $BITS -e signed-integer -r $RATE -c 1 "$TEMP_AUDIO" trim 0 $DURATION 2>/dev/null

    # Check if recording was successful
    if [ $? -ne 0 ] || [ ! -f "$TEMP_AUDIO" ]; then
        debug_log "Failed to record audio from $INPUT_DEVICE"

        # Attempt to switch device
        if switch_audio_device; then
            consecutive_zero_audio=0
            continue
        else
            if ! $JSON_OUTPUT && ! $HEADLESS; then
                clear_line
                echo -e "${RED}Audio recording failed. Check device connection.${NC}"
            fi
            sleep 10
            continue
        fi
    fi

    # Analyze the recorded audio and extract the level
    audio_stat=$(sox -t wav "$TEMP_AUDIO" -n stat 2>&1)
    audio_level=$(echo "$audio_stat" | awk '/RMS[[:space:]]+amplitude/ {print $3}')
    audio_level=$(echo "$audio_level" | tr ',' '.')

    # Validate audio level
    if [ -z "$audio_level" ] || ! [[ "$audio_level" =~ ^[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$ ]]; then
        audio_level=0.0
        debug_log "RMS amplitude not found or invalid, defaulting audio level to 0.0"
    fi

    debug_log "Audio level: $audio_level (threshold: $AUDIO_THRESHOLD)"

    # Check if audio level is too low
    if (($(echo "$audio_level < $AUDIO_THRESHOLD" | bc -l))); then
        debug_log "Audio level too low ($audio_level), skipping recognition"

        # Check if audio level is exactly zero (device might be disconnected)
        if (($(echo "$audio_level == 0" | bc -l))); then
            ((consecutive_zero_audio++))
            debug_log "Zero audio level detected (count: $consecutive_zero_audio)"

            # Switch device if we've had too many consecutive zero readings
            if ((consecutive_zero_audio >= MAX_CONSECUTIVE_ZERO_AUDIO)); then
                if switch_audio_device; then
                    consecutive_zero_audio=0
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

    # Perform recognition using the already recorded audio
    if [[ "${SHAMON_BACKGROUND:-}" == "true" ]]; then
        # In background mode, suppress vibra stderr
        result=$(sox -t wav "$TEMP_AUDIO" -t raw -b $BITS -e signed-integer -r $RATE -c 1 - 2>/dev/null |
            vibra --recognize --seconds $DURATION --rate $RATE --channels 1 --bits $BITS 2>/dev/null)
    else
        # In interactive mode, allow vibra stderr for debugging
        result=$(sox -t wav "$TEMP_AUDIO" -t raw -b $BITS -e signed-integer -r $RATE -c 1 - 2>/dev/null |
            vibra --recognize --seconds $DURATION --rate $RATE --channels 1 --bits $BITS)
    fi

    # Validate and process JSON response
    if ! echo "$result" | jq -e . >/dev/null 2>&1; then
        debug_log "Invalid JSON response from Vibra"
        ((consecutive_empty++))
        INTERVAL=$((BASE_INTERVAL * consecutive_empty))
        if ((INTERVAL > MAX_INTERVAL)); then
            INTERVAL=$MAX_INTERVAL
        fi
        continue
    fi

    # Check if track information exists
    if echo "$result" | jq -e '.track' >/dev/null 2>&1; then
        # Extract song information efficiently with a single jq call
        # Use IFS=$'\t' to split only on tab, not spaces (handles multi-word titles like "Ray of Light")
        IFS=$'\t' read -r title artist < <(echo "$result" | jq -r '.track | "\(.title)\t\(.subtitle)"')

        # Trim title (remove content in parentheses)
        title=$(echo "$title" | sed 's/ *(.*//')

        song_info="$title by $artist"
        timestamp=$(date '+%H:%M:%S')

        # Create fuzzy match key using first word of title and artist
        # This handles variations like "Fastlove, Pt. 1" vs "Fastlove (Promo Edit)"
        # or "George Michael" vs "George Michael feat. Someone"
        title_first_word=$(echo "$title" | awk '{print $1}' | tr -d ',' | tr '[:upper:]' '[:lower:]')
        artist_first_word=$(echo "$artist" | awk '{print $1}' | tr -d ',' | tr '[:upper:]' '[:lower:]')
        match_key="${title_first_word}|${artist_first_word}"

        # Only process if it's a different song from last detection
        if [[ "$last_song" != "$match_key" ]]; then
            INTERVAL=$BASE_INTERVAL
            last_song="$match_key"
            debug_log "New song detected (match key: $match_key) - $song_info"

            if $JSON_OUTPUT; then
                echo "$result" | jq -c --arg ts "$timestamp" --arg al "$audio_level" \
                    '{timestamp: $ts, title: .track.title, artist: .track.subtitle, audio_level: ($al | tonumber)}'
            elif ! $HEADLESS && [[ "${SHAMON_BACKGROUND:-}" != "true" ]]; then
                clear_line
                echo -e "${GREEN}[$timestamp] $song_info${NC}"
            else
                # In headless/background mode, log to debug log
                debug_log "[$timestamp] $song_info"
            fi

            # Use safe SQL escaping function
            title_escaped=$(sql_escape "$title")
            artist_escaped=$(sql_escape "$artist")

            # Insert into database with escaped values
            sqlite3 "$DB_FILE" <<EOF
INSERT INTO songs (timestamp, title, artist, audio_level)
VALUES (datetime('now', 'localtime'), '$title_escaped', '$artist_escaped', $audio_level);
EOF

        else
            # Same song detected (fuzzy match), increase interval gradually
            INTERVAL=$((INTERVAL + INTERVAL_INCREMENT))
            if ((INTERVAL > SAME_SONG_MAX_INTERVAL)); then
                INTERVAL=$SAME_SONG_MAX_INTERVAL
            fi
            debug_log "Same song detected (fuzzy match: $match_key), interval increased to $INTERVAL"
        fi
        consecutive_empty=0

    else
        # No track found
        ((consecutive_empty++))
        INTERVAL=$((BASE_INTERVAL * consecutive_empty))
        if ((INTERVAL > MAX_INTERVAL)); then
            INTERVAL=$MAX_INTERVAL
        fi
        debug_log "No track found in response (attempt $consecutive_empty)"
    fi

    # Show "No music detected" after several empty results
    if ((consecutive_empty >= MAX_RECOGNITION_RETRIES)) && ! $JSON_OUTPUT && ! $HEADLESS && [[ "${SHAMON_BACKGROUND:-}" != "true" ]]; then
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
# ./shamon.sh              # Normal mode with debug info
# ./shamon.sh --json       # JSON output mode
# ./shamon.sh --debug      # Debug mode
# ./shamon.sh --auto-input # Auto-select input device from preferred list
# ./shamon.sh --headless   # Run in background without console output
# ./shamon.sh --version    # Show version information
# ./shamon.sh --help       # Show help message
#
# Query history:
# sqlite3 ~/.music_monitor.db "SELECT datetime(timestamp, 'localtime'),
#     title, artist FROM songs ORDER BY timestamp DESC LIMIT 10;"
###########################################
