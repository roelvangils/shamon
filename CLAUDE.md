# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Shamon is a CLI tool that continuously monitors and identifies music playing on your computer using Vibra for audio fingerprinting and the Shazam API. It records audio samples, processes them for recognition, and stores results in a local SQLite database.

## Commands

### Main Operations
- `./shamon.sh` - Run main script with audio device selection and debug logging
- `./shamon.sh --json` - Output in JSON format
- `./shamon.sh --debug` - Enable debug mode (logs to ~/.music_monitor.log)
- `./shamon.sh --auto-input` - Auto-select input device from preferred list
- `./shamon.sh --headless` - Run in background without console output
- `./shamon_ram.sh` - RAM-optimized version using named pipes instead of temp files
- `./detect_audio_level.sh` - Debug audio capture and show RMS amplitude levels

### Background/Daemon Modes
- `./shamon_daemon.sh` - Run in daemon mode (maintains audio access)
- `./shamon_background.sh` - Launch in minimized Terminal window (macOS)
- Install as LaunchAgent: `cp com.shamon.music-monitor.plist ~/Library/LaunchAgents/`

### Database Queries
- Check recognition history: `sqlite3 ~/.music_monitor.db "SELECT datetime(timestamp, 'localtime'), title, artist FROM songs ORDER BY timestamp DESC LIMIT 10;"`
- View full database schema: `sqlite3 ~/.music_monitor.db ".schema"`

### Web Server
- Start API server: `python serve.py` (runs on port 1979)
- Endpoints: `/json` (JSON data), `/table` (HTML table with cyberpunk styling)

## Architecture

### Core Components
1. **Audio Capture**: Uses SoX to record 5-second samples from selected audio device
2. **Level Detection**: Calculates RMS amplitude to skip silence (threshold: 0.0001)
3. **Recognition**: Sends audio to Vibra, which uses Shazam API for identification
4. **Storage**: SQLite database (~/.music_monitor.db) stores timestamp, title, artist, audio_level
5. **Interval Management**: Dynamically adjusts check frequency (increases when same song detected)

### Data Flow
```
Audio Device → SoX Recording → Audio Level Check → Vibra Recognition → SQLite Storage
                                     ↓                                        ↓
                              (Skip if silent)                    Console/JSON Output
```

### Key Features
- Interactive audio device selection on startup
- Auto-input mode with preferred device list (C922 Pro Stream Webcam, MacBook Pro Microphone)
- Automatic device switching when audio input fails (zero audio level detection)
- Headless mode for background operation (logs to ~/.music_monitor.log or ~/.music_monitor_ram.log)
- Network connectivity validation before recognition attempts
- Automatic cleanup of temporary files (trap handlers)
- Color-coded terminal output (green for new songs, yellow for repeats)
- Debug logging with timestamps
- Skip wait time by pressing Enter

## Code Style Guidelines
- **Shell Scripts**: Use bash (`#!/bin/bash`) for all scripts
- **Comments**: Add descriptive section headers (`###########################################`)
- **Variables**: Use UPPERCASE for global constants, lowercase for function-local variables
- **Indentation**: Use 4 spaces for indentation in shell scripts
- **Functions**: Include descriptive comments before each function
- **Error Handling**: Check command exit codes (`if [ $? -ne 0 ]`)
- **String Formatting**: Use ANSI color codes for terminal output
- **Database Access**: Escape SQL inputs using `sed "s/'/''/g"`
- **Debug Logging**: Use the debug_log function for consistent debugging
- **Cleanup**: Include trap handlers for proper resource cleanup

## Development Practices
- Test audio capture on different systems using `./detect_audio_level.sh`
- Validate audio processing before song recognition (check RMS levels)
- Consider network connectivity in implementation
- Ensure proper SQLite database access and escaping
- Monitor debug logs when troubleshooting: `tail -f ~/.music_monitor.log`

## Dependencies
- **Vibra**: Must be installed separately (see https://github.com/BayernMuller/vibra)
- **SoX**: Audio recording and processing (`sox` command)
- **jq**: JSON parsing for Vibra output
- **sqlite3**: Database operations
- **bc**: Floating-point calculations for audio levels
- **Python**: FastAPI and uvicorn for web server (serve.py)