# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Shamon v1.2.3 is a CLI tool that continuously monitors and identifies music playing on your computer using Vibra for audio fingerprinting and the Shazam API. It records audio samples, processes them for recognition, and stores results in a local SQLite database.

## Commands

### Main Operations
- `./shamon.sh` - Run main script with audio device selection
- `./shamon.sh --json` - Output in JSON format
- `./shamon.sh --debug` - Enable debug mode (logs to ~/.music_monitor.log)
- `./shamon.sh --auto-input` - Auto-select input device from preferred list
- `./shamon.sh --headless` - Run in background without console output
- `./shamon.sh --version` - Show version information
- `./shamon.sh --help` - Show help message and usage
- `./detect_audio_level.sh` - Debug audio capture and show RMS amplitude levels

### Background/Daemon Modes
- `./shamon_daemon.sh` - Run in daemon mode (maintains audio access)
- `./shamon_background.sh` - Launch in minimized Terminal window (macOS)
- Install as LaunchAgent: `cp com.shamon.music-monitor.plist ~/Library/LaunchAgents/` (update paths first)

### Database Queries
- Check recognition history: `sqlite3 ~/.music_monitor.db "SELECT datetime(timestamp, 'localtime'), title, artist FROM songs ORDER BY timestamp DESC LIMIT 10;"`
- View full database schema: `sqlite3 ~/.music_monitor.db ".schema"`
- Get statistics: `sqlite3 ~/.music_monitor.db "SELECT COUNT(*) as total, COUNT(DISTINCT title || artist) as unique_songs FROM songs;"`

### Web Server
- Start API server: `python serve.py` (runs on port 8080)
- Install dependencies first: `pip install -r requirements.txt`
- Endpoints:
  - `/` - API information
  - `/json?limit=N` - Song data as JSON (default 100 songs)
  - `/table?limit=N` - HTML table with cyberpunk styling
  - `/stats` - Database statistics

## Configuration

Users can create `~/.shamonrc` to customize behavior:

```bash
# Preferred audio input devices (in order of preference)
PREFERRED_DEVICES=(
    "My Webcam"
    "Built-in Microphone"
)

# Audio detection threshold (default: 0.01)
AUDIO_THRESHOLD=0.005

# Interval settings (in seconds)
BASE_INTERVAL=15
MAX_INTERVAL=120

# Enable debug mode
DEBUG=true
```

## Architecture

### Core Components
1. **Audio Capture**: Uses SoX to record 5-second samples from selected audio device
2. **Level Detection**: Calculates RMS amplitude to skip silence (configurable threshold, default: 0.01)
3. **Recognition**: Sends audio to Vibra, which uses Shazam API for identification
4. **Storage**: SQLite database (~/.music_monitor.db) stores timestamp, title, artist, audio_level
5. **Interval Management**: Dynamically adjusts check frequency (increases when same song detected)

### Code Structure
- `shamon.sh` - Main monitoring script (uses common.sh)
- `common.sh` - Shared functions library (colors, logging, device switching, SQL escaping)
- `serve.py` - FastAPI web server for viewing database
- `requirements.txt` - Python dependencies (fastapi, uvicorn)

### Data Flow
```
Audio Device → SoX Recording → Audio Level Check → Vibra Recognition → SQLite Storage
                                     ↓                                        ↓
                              (Skip if silent)                    Console/JSON Output
```

### Key Features
- Interactive audio device selection on startup with input validation
- Auto-input mode with preferred device list (configurable via ~/.shamonrc)
- Automatic device switching when audio input fails (zero audio level detection)
- Headless mode for background operation with screen session support
- Network connectivity validation before recognition attempts
- Automatic cleanup of temporary files (trap handlers)
- Color-coded terminal output (green for new songs, gray for "no music")
- Debug logging with timestamps to file
- Skip wait time by pressing Enter in interactive mode
- Configuration file support (~/.shamonrc)
- Version information (--version flag)
- Help system (--help flag)
- Optimized audio recording (single recording used for both level check and recognition)
- Fuzzy song matching (compares first word of title and artist to handle variations like "Fastlove, Pt. 1" vs "Fastlove (Promo Edit)")

## Code Style Guidelines

### Shell Scripts
- **Shebang**: Use `#!/bin/bash` for all scripts
- **Comments**: Add descriptive section headers with `###########################################`
- **Variables**: Use UPPERCASE for global constants, lowercase for function-local variables
- **Indentation**: Use 4 spaces for indentation
- **Functions**: Include descriptive comments before each function with purpose and parameters
- **Error Handling**: Always check command exit codes and handle failures gracefully
- **String Formatting**: Use ANSI color codes from common.sh (GREEN, BLUE, GRAY, RED, YELLOW, NC)

### SQL and Security
- **Database Access**: Use the `sql_escape()` function from common.sh for all user input
- **SQL Injection**: NEVER use direct string interpolation for SQL queries with user data
- **Parameterized Queries**: Use heredocs for multi-line SQL for clarity
- **Validation**: Validate numeric inputs before using in bc calculations

### Error Messages
- **User-Friendly**: Provide clear error messages with actionable solutions
- **Installation Help**: Use `get_install_command()` to suggest package installation
- **Context**: Include relevant details (file paths, device names) in error messages

### Logging and Debugging
- **Debug Logging**: Use the `debug_log()` function for all debug output
- **Log Location**: Logs go to ~/.music_monitor.log (or _launchd.log for LaunchAgent)
- **Timestamps**: Debug logs include timestamps automatically
- **Verbosity**: Debug mode shows internal state, audio levels, and decision logic

### Resource Management
- **Temporary Files**: Always clean up temporary files in the cleanup() function
- **Trap Handlers**: Use `trap cleanup INT TERM EXIT` for proper cleanup
- **Terminal State**: Save and restore terminal settings (stty, cursor visibility)
- **File Descriptors**: Close all database connections after use

### Python Code
- **Type Hints**: Use type hints for function parameters and return values
- **Docstrings**: Include docstrings for all functions and modules
- **Error Handling**: Use FastAPI's HTTPException for API errors
- **Security**: Never expose database path in error messages to end users (already handled)

## Development Practices

### Testing
- Test audio capture on different systems using `./detect_audio_level.sh`
- Validate audio processing before song recognition (check RMS levels)
- Test device switching by disconnecting/reconnecting USB devices
- Verify SQL escaping with song titles containing apostrophes
- Test configuration file loading with invalid syntax

### Debugging
- Enable debug mode: `./shamon.sh --debug`
- Monitor logs: `tail -f ~/.music_monitor.log`
- Check audio levels: `./detect_audio_level.sh`
- Verify device list: Run `./shamon.sh` interactively to see available devices
- Test vibra directly: `echo "test" | vibra --recognize --seconds 5`

### Performance Considerations
- Audio is recorded once and used for both level detection and recognition
- Network check caches result for 30 seconds on failure
- Database writes use transactions for consistency
- jq parsing is optimized with single invocations where possible

### Common Issues
1. **Device Not Found**: Update PREFERRED_DEVICES in ~/.shamonrc with exact device names
2. **Zero Audio Levels**: Check device permissions and application audio routing
3. **Background Mode Fails**: Install `screen` for proper background support on macOS
4. **SQL Errors**: Ensure all user input goes through sql_escape() function
5. **Network Timeouts**: Vibra requires internet connection to Shazam API

## Dependencies

### System Dependencies (Required)
- **Vibra**: Audio fingerprinting tool (https://github.com/BayernMuller/vibra)
- **SoX**: Audio recording and processing (`brew install sox`)
- **jq**: JSON parsing for Vibra output (`brew install jq`)
- **sqlite3**: Database operations (usually pre-installed)
- **bc**: Floating-point calculations for audio levels (usually pre-installed)

### Optional Dependencies
- **screen**: Better background mode support (`brew install screen`)

### Python Dependencies (For Web Server)
- **FastAPI**: Web framework (`pip install fastapi`)
- **Uvicorn**: ASGI server (`pip install uvicorn`)
- Install both: `pip install -r requirements.txt`

## File Descriptions

- `shamon.sh` (577 lines) - Main monitoring script with full feature set
- `common.sh` (153 lines) - Shared functions library (colors, logging, device switching, SQL escaping)
- `serve.py` (297 lines) - FastAPI web server for viewing database
- `detect_audio_level.sh` (47 lines) - Audio debugging utility
- `shamon_daemon.sh` (25 lines) - Simple daemon wrapper
- `shamon_background.sh` (26 lines) - macOS background launcher using osascript
- `com.shamon.music-monitor.plist` (46 lines) - LaunchAgent configuration (update paths before use)
- `requirements.txt` - Python dependencies list
- `README.md` - User documentation with installation and troubleshooting
- `CLAUDE.md` - This file, developer documentation

## Song Matching Algorithm

### Title-based Matching with Time Window

Shamon uses title-based matching with a time window to detect when the same song is recognized multiple times, even when Shazam returns different artist credits:

**Problem:** Shazam often returns variations like:
- "You Got The Love" by "Candi Staton" vs "You Got the Love" by "The Source & Candi Staton"
- "Fastlove, Pt. 1" vs "Fastlove (Promo Edit)"

**Solution:** Compare first 3 words of title (normalized) with a 60-second time window:
```bash
# Normalize title: first 3 words, lowercase, remove punctuation
title_normalized=$(echo "$title" | awk '{print $1, $2, $3}' | tr '[:upper:]' '[:lower:]' | tr -d ',')
current_time=$(date +%s)

# Consider same song if title matches AND within 60 seconds
if [[ "$last_song" != "$title_normalized" ]] || ((current_time - last_detection_time > 60)); then
    # New song - save to database and display
    last_song="$title_normalized"
    last_detection_time=$current_time
else
    # Same song - increase interval to reduce API calls
fi
```

**Benefits:**
- Handles artist credit variations (same song, different artist attributions)
- Prevents duplicate database entries for the same song
- Reduces API calls by increasing check interval for repeated songs
- Still saves full title and artist details to database for accuracy
- Time window allows same song to be logged again after 60 seconds (e.g., if replayed)

**Edge cases handled:**
- Case variations ("The" vs "the")
- Different artist credits for same song
- Punctuation variations

## Recent Changes (v1.1.0)

### Security Improvements
- Fixed SQL injection vulnerability using dedicated sql_escape() function
- Added input validation for device selection with range checking
- Improved error messages to avoid exposing sensitive paths

### Code Quality
- Extracted common functions to common.sh library
- Removed shamon_ram.sh (experimental, no longer maintained)
- Replaced magic numbers with named constants
- Fixed Dutch comments to English
- Improved terminal state restoration
- Added comprehensive cleanup of temporary files

### Features
- Added configuration file support (~/.shamonrc)
- Added --version and --help flags
- Optimized audio recording (single recording for level + recognition)
- Combined multiple jq calls into single efficient invocations
- Better error handling with installation suggestions
- Improved web server with stats endpoint
- Implemented fuzzy song matching (first word comparison) to handle Shazam variations

### Documentation
- Comprehensive troubleshooting section in README
- Better inline documentation
- Updated all command examples
- Added configuration examples

## Version History

- **v1.2.3** (Current) - Improved song matching (title + time window), mic-first device fallback
- **v1.2.2** - Network check caching, device fallback improvements, XSS fix
- **v1.2.1** - Fix parsing of multi-word song titles
- **v1.2.0** - Fuzzy song matching to handle Shazam variations
- **v1.1.0** - Major refactoring with security fixes and new features
- **v1.0.0** - Initial release with basic monitoring functionality
