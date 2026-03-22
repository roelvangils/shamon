# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Shamon v2.0.0 is a Python CLI tool that continuously monitors and identifies music playing on your computer using Vibra for audio fingerprinting and the Shazam API. It records audio samples, processes them for recognition, and stores results in a local SQLite database.

## Commands

### Main Operations
- `python3 shamon.py` - Run with interactive audio device selection
- `python3 shamon.py --json` - Output in JSON format
- `python3 shamon.py --debug` - Enable debug mode (logs to ~/.music_monitor.log)
- `python3 shamon.py --auto-input` - Auto-select input device from preferred list
- `python3 shamon.py --headless` - Run in background without console output
- `python3 shamon.py --version` - Show version information
- `python3 shamon.py --help` - Show help message and usage
- `./detect_audio_level.sh` - Debug audio capture and show RMS amplitude levels

### Background/Daemon Modes
- `python3 shamon.py --auto-input --headless` - Headless background mode
- Install as LaunchAgent: `cp com.shamon.music-monitor.plist ~/Library/LaunchAgents/` (update paths first)

### Database Queries
- Check recognition history: `sqlite3 ~/.music_monitor.db "SELECT datetime(timestamp, 'localtime'), title, artist FROM songs ORDER BY timestamp DESC LIMIT 10;"`
- View full database schema: `sqlite3 ~/.music_monitor.db ".schema"`
- Get statistics: `sqlite3 ~/.music_monitor.db "SELECT COUNT(*) as total, COUNT(DISTINCT title || artist) as unique_songs FROM songs;"`

### Web Servers
- **Dashboard server**: `python3 serve.py` (port 8080, requires FastAPI)
  - `/` - API information
  - `/json?limit=N` - Song data as JSON (default 100 songs)
  - `/table?limit=N` - HTML table with cyberpunk styling
  - `/stats` - Database statistics
- **Lightweight API**: `python3 shamon_api.py` (port 8888, zero dependencies)
  - `GET /` - Current song as JSON
  - `GET /?offset=1` - Previous song

## Configuration

Users can create `~/.shamonrc` to customize behavior (bash-style syntax, parsed by Python):

```bash
# Preferred audio input devices (in order of preference)
PREFERRED_DEVICES=(
    "My Webcam"
    "Built-in Microphone"
)

# Audio detection threshold (default: 0.0005)
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
2. **Audio Normalization**: SoX normalizes audio to 0dB before recognition for better results
3. **Level Detection**: Calculates RMS amplitude to skip silence (configurable threshold, default: 0.0005)
4. **Recognition**: Pipes normalized PCM audio to Vibra, which uses Shazam API for identification
5. **Storage**: SQLite database (~/.music_monitor.db) stores timestamp, title, artist, audio_level
6. **Interval Management**: Dynamically adjusts check frequency with silence backoff (up to 1 hour)

### Code Structure
- `shamon.py` (832 lines) - Main monitoring tool: `ShamonMonitor` class, `Config` dataclass, CLI entry point
- `shamon_api.py` (80 lines) - Zero-dependency lightweight API server (stdlib `http.server`)
- `serve.py` (299 lines) - FastAPI web dashboard for viewing database history
- `detect_audio_level.sh` (47 lines) - Audio debugging utility
- `requirements.txt` - Python dependencies (fastapi, uvicorn — for serve.py only)
- `com.shamon.music-monitor.plist` (77 lines) - macOS LaunchAgent configuration

### Data Flow
```
Audio Device → SoX Recording → Audio Level Check → SoX Normalize → Vibra Recognition → SQLite Storage
                                     ↓                                                       ↓
                              (Skip if silent)                                     Console/JSON Output
```

### Key Classes
- **`Config`** (dataclass) - All configuration settings with defaults, loaded from `~/.shamonrc`
- **`ShamonMonitor`** - Main monitoring class with methods for recording, recognition, device management
- **`Colors`** - ANSI color code constants

### Key Features
- Interactive audio device selection on startup with input validation
- Auto-input mode with preferred device list (configurable via ~/.shamonrc)
- Automatic device switching when audio input fails (zero audio level detection)
- Clamshell mode detection (excludes built-in mic when MacBook lid is closed)
- Headless mode for background operation
- Audio normalization for improved recognition accuracy
- Network connectivity validation with 30-second cache on failure
- Automatic cleanup of temporary files (atexit + signal handlers)
- Color-coded terminal output (green for new songs, gray for "no music")
- Debug logging with timestamps to file
- Skip wait time by pressing Enter in interactive mode
- Silence backoff: gradually increases interval up to 1 hour during silence
- Title normalization for deduplication (removes subtitles, part numbers, punctuation)

## Code Style Guidelines

### Python Code
- **Type Hints**: Use type hints for function parameters and return values
- **Docstrings**: Include docstrings for classes and public methods
- **Error Handling**: Catch specific exceptions, not bare `except`
- **Subprocess**: Use `subprocess.run()` with `capture_output=True` and `timeout`
- **Temp Files**: Use `tempfile.mkstemp()` (not deprecated `mktemp`)
- **Security**: Use parameterized SQL queries (never string interpolation)
- **Constants**: Use class-level constants and `Config` dataclass fields
- **Indentation**: 4 spaces

### Shell Scripts (detect_audio_level.sh)
- **Shebang**: Use `#!/bin/bash`
- **Variables**: UPPERCASE for constants
- **Error Handling**: Check command exit codes

### Error Messages
- Provide clear error messages with actionable solutions
- Include installation suggestions for missing dependencies
- Never expose internal paths in API error messages

### Resource Management
- Temporary files cleaned up via `atexit` handler and signal handlers (SIGINT, SIGTERM)
- Terminal settings saved and restored on exit
- Database connections use `with` context manager

## Development Practices

### Testing
- Test audio capture: `./detect_audio_level.sh`
- Verify version: `python3 shamon.py --version`
- Test help: `python3 shamon.py --help`
- Test import: `python3 -c "import shamon_api"`
- Test device switching by disconnecting/reconnecting USB devices

### Debugging
- Enable debug mode: `python3 shamon.py --debug`
- Monitor logs: `tail -f ~/.music_monitor.log`
- Check audio levels: `./detect_audio_level.sh`
- Test vibra directly: `echo "test" | vibra --recognize --seconds 5`

### Common Issues
1. **Device Not Found**: Update PREFERRED_DEVICES in ~/.shamonrc with exact device names
2. **Zero Audio Levels**: Check device permissions and application audio routing
3. **Clamshell Mode**: Built-in mic is excluded when MacBook lid is closed — use an external mic
4. **Network Timeouts**: Vibra requires internet connection to Shazam API

## Dependencies

### System Dependencies (Required)
- **Python 3**: Runtime (usually pre-installed on macOS)
- **Vibra**: Audio fingerprinting tool (https://github.com/BayernMuller/vibra)
- **SoX**: Audio recording, normalization, and level detection (`brew install sox`)
- **sqlite3**: Database operations (usually pre-installed)

### Python Dependencies (For serve.py only)
- **FastAPI**: Web framework
- **Uvicorn**: ASGI server
- Install: `pip install -r requirements.txt`

Note: `shamon.py` and `shamon_api.py` use only the Python standard library — no pip install needed.

## Song Matching Algorithm

### Title Normalization with Deduplication

Shamon normalizes song titles to detect when the same song is recognized multiple times:

**Problem:** Shazam returns variations like:
- "Fly" vs "Fly - Through the Starry Night" (subtitles after dash)
- "Fastlove, Pt. 1" vs "Fastlove" (part numbers)
- "You Got The Love" vs "You Got the Love" (case differences)

**Solution:** Normalize titles by removing subtitles, part numbers, and punctuation, then compare first 3 words:
```python
def normalize_title(self, title: str) -> str:
    cleaned = re.sub(r'\s*[-–—:]\s.*$', '', title)           # Remove subtitles
    cleaned = re.sub(r',?\s*(pt\.?|part)\s*\d+', '', cleaned, flags=re.IGNORECASE)  # Remove parts
    cleaned = re.sub(r'[,\'"!?.]', '', cleaned.lower())      # Remove punctuation
    return ' '.join(cleaned.split()[:3])                       # First 3 words
```

**Benefits:**
- Same song is never logged twice in a row (strict deduplication)
- Handles subtitle, part number, case, and punctuation variations
- Increases check interval for repeated songs to reduce API calls
- Full title and artist still saved to database for accuracy

## Version History

- **v2.0.0** (Current) - Complete rewrite from Bash to Python. New: `ShamonMonitor` class, `Config` dataclass, audio normalization, clamshell detection, silence backoff, improved title normalization
- **v1.2.3** - Improved song matching (title + time window), mic-first device fallback
- **v1.2.2** - Network check caching, device fallback improvements, XSS fix
- **v1.2.1** - Fix parsing of multi-word song titles
- **v1.2.0** - Fuzzy song matching to handle Shazam variations
- **v1.1.0** - Major refactoring with security fixes and new features
- **v1.0.0** - Initial release with basic monitoring functionality
