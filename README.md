# Shamon - Music Recognition Monitor

A lightweight CLI tool that continuously monitors and identifies music playing on your computer using Vibra for audio fingerprinting and the Shazam API. Shamon is smarter than running Shazam manually — it normalizes audio for better recognition, intelligently avoids duplicate detections, minimizes API calls, and automatically handles device failures.

## Why Shamon?

| Feature | Shazam App | Shamon |
|---------|------------|--------|
| Recognizes quiet audio | ❌ | ✅ Audio normalized to -3dB before recognition |
| Avoids duplicate entries | ❌ | ✅ Intelligent title matching with time window |
| Runs continuously | ❌ | ✅ Background monitoring with auto-recovery |
| Handles device failures | ❌ | ✅ Automatic fallback to next available mic |
| Minimal API usage | ❌ | ✅ Skips silence, increases interval for same song |
| Local history | ❌ | ✅ SQLite database with web interface |

## Features

### Intelligent Audio Processing
- **Audio normalization** — Boosts quiet recordings to -3dB before sending to Shazam, recognizing music that would otherwise be missed
- **Smart silence detection** — Skips API calls when no audio is detected (threshold: 0.001 RMS)
- **Single recording, dual use** — Same audio sample used for level detection and recognition (no wasted recordings)

### Smart Song Matching
- **Title-based matching** — Compares first 3 words of song titles (case-insensitive)
- **Time window deduplication** — Same song within 60 seconds is considered a repeat
- **Handles artist variations** — "You Got The Love" by "Candi Staton" and "The Source & Candi Staton" are correctly matched

### Minimal API Footprint
- **Adaptive intervals** — Increases wait time when the same song keeps playing
- **Network check caching** — Caches connectivity status for 30 seconds
- **Skip on silence** — No API calls when audio level is below threshold

### Reliable Device Handling
- **Automatic device switching** — Switches to next device after 3 consecutive zero-audio readings
- **Mic-first fallback** — Prioritizes devices with "mic" in the name when searching for alternatives
- **Preferred device list** — Configure your preferred devices in order of priority

### Additional Features
- 📊 SQLite database storage for recognition history
- 🌐 Web server with JSON API and cyberpunk-styled HTML interface
- 🎨 Colored terminal output with real-time status
- ⚙️ Configurable via `~/.shamonrc` file
- 🐛 Debug mode with detailed logging
- 📱 JSON output mode for integration with other tools
- 💻 Background/headless operation with screen support

## Installation

### Prerequisites

First, install [Vibra](https://github.com/BayernMuller/vibra) on your system. Follow the instructions in the Vibra repository.

### System Dependencies

Install required system dependencies:

**macOS:**
```bash
brew install sox jq sqlite3 bc screen
```

**Linux (Ubuntu/Debian):**
```bash
sudo apt-get install sox jq sqlite3 bc screen
```

### Python Dependencies (for web server)

If you want to use the web interface:

```bash
pip install -r requirements.txt
```

Or install manually:
```bash
pip install fastapi uvicorn
```

## Usage

### Basic Commands

```bash
./shamon.sh                        # Interactive mode with device selection
./shamon.sh --json                 # JSON output mode
./shamon.sh --debug                # Debug mode with logging
./shamon.sh --auto-input           # Auto-select input device from preferred list
./shamon.sh --headless             # Run in background without console output
./shamon.sh --version              # Show version information
./shamon.sh --help                 # Show help message
```

### Combined Flags

You can combine multiple flags:

```bash
./shamon.sh --auto-input --headless       # Auto-select device and run in background
./shamon.sh --auto-input --debug          # Auto-select with debug logging
./shamon.sh --json --auto-input           # JSON output with auto-selected device
```

## Configuration

Create a `~/.shamonrc` file to customize Shamon's behavior:

```bash
# Preferred audio input devices (in order of preference)
PREFERRED_DEVICES=(
    "My Webcam"
    "Built-in Microphone"
)

# Audio detection threshold (default: 0.001, very sensitive due to normalization)
AUDIO_THRESHOLD=0.001

# Base interval between checks (in seconds)
BASE_INTERVAL=15

# Maximum interval between checks
MAX_INTERVAL=120

# Enable debug mode by default
DEBUG=true
```

## Headless Mode

When using the `--headless` flag, the script will:
- Start in the background and immediately return control to the terminal
- Display the process ID (PID) for managing the background process
- Log all output to `~/.music_monitor.log`
- Continue monitoring music until stopped

### macOS Audio Access in Background

On macOS, background processes may lose access to CoreAudio devices. Shamon handles this automatically with several options:

#### Option 1: Screen Session (Recommended)

If `screen` is installed, Shamon will automatically use it to maintain audio access:

```bash
# Install screen if needed
brew install screen

# Start with screen support
./shamon.sh --auto-input --headless
```

Output:
```
📻 Music Monitor started in background mode (screen session)
Screen session: shamon_12345
Process ID: 12345
Log file: ~/.music_monitor.log
To view: screen -r shamon_12345
To stop: screen -S shamon_12345 -X quit
```

#### Option 2: Background Launcher Script

Use the provided launcher script that maintains Terminal.app context:

```bash
./shamon_background.sh
```

#### Option 3: LaunchAgent (Auto-start at Login)

Install as a LaunchAgent for persistent operation:

```bash
# Copy the plist file
cp com.shamon.music-monitor.plist ~/Library/LaunchAgents/

# Update the paths in the plist file to match your installation directory
nano ~/Library/LaunchAgents/com.shamon.music-monitor.plist

# Load the service
launchctl load ~/Library/LaunchAgents/com.shamon.music-monitor.plist

# Stop the service
launchctl unload ~/Library/LaunchAgents/com.shamon.music-monitor.plist

# View logs
tail -f ~/.music_monitor_launchd.log
```

## Automatic Device Switching

When using `--auto-input`, Shamon includes automatic failover between audio devices:

- If the current audio device produces zero audio levels for 3 consecutive checks, it automatically switches to the next available preferred device
- The preferred devices list is checked in order
- This ensures continuous monitoring even when devices are disconnected or reconnected
- The script will cycle through all available preferred devices before giving up

This feature is especially useful for long-running sessions where USB devices might be temporarily disconnected.

## Web Server

Start the web server to view your music history:

```bash
python serve.py
```

The server runs on port 8080 and provides:

- **http://localhost:8080/** - API information
- **http://localhost:8080/json** - Song data as JSON (supports `?limit=N` parameter)
- **http://localhost:8080/table** - Song data as cyberpunk-styled HTML table
- **http://localhost:8080/stats** - Database statistics

## Database Queries

Songs are stored in `~/.music_monitor.db`. You can query the database directly:

### View Last 10 Songs

```bash
sqlite3 ~/.music_monitor.db "SELECT datetime(timestamp, 'localtime'), title, artist FROM songs ORDER BY timestamp DESC LIMIT 10;"
```

### View Database Schema

```bash
sqlite3 ~/.music_monitor.db ".schema"
```

### Get Song Count

```bash
sqlite3 ~/.music_monitor.db "SELECT COUNT(*) FROM songs;"
```

### Find Most Detected Song

```bash
sqlite3 ~/.music_monitor.db "SELECT title, artist, COUNT(*) as count FROM songs GROUP BY title, artist ORDER BY count DESC LIMIT 1;"
```

## Troubleshooting

### No Audio Devices Found

**Problem:** `Error: No input devices found.`

**Solution:**
1. Check that your audio device is connected and recognized by macOS:
   ```bash
   system_profiler SPAudioDataType
   ```
2. Verify SoX can see your devices:
   ```bash
   sox -V3 -n -t coreaudio dummy trim 0 1 2>&1 | grep "Found Audio Device"
   ```
3. Try reconnecting your USB audio device
4. Check System Preferences > Security & Privacy > Microphone permissions

### Audio Recording Fails

**Problem:** `Audio recording failed. Check device connection.`

**Solution:**
1. The selected device may be in use by another application
2. Try closing other audio applications (Zoom, Teams, etc.)
3. Check microphone permissions in System Preferences
4. Restart the device or computer
5. Use a different audio device with `--auto-input`

### Vibra Not Found

**Problem:** `Error: vibra is not installed`

**Solution:**
Install Vibra following the instructions at https://github.com/BayernMuller/vibra

For macOS with Homebrew:
```bash
brew install vibra
```

### Network Unavailable

**Problem:** `Network unavailable, waiting...`

**Solution:**
1. Check your internet connection
2. Verify you can reach external servers:
   ```bash
   ping -c 3 8.8.8.8
   ```
3. If behind a firewall, ensure outbound connections are allowed
4. Vibra needs to connect to Shazam's API servers

### Database Locked

**Problem:** SQLite database is locked

**Solution:**
1. Check if another instance of Shamon is running:
   ```bash
   ps aux | grep shamon
   ```
2. Kill other instances if found:
   ```bash
   pkill -f shamon.sh
   ```
3. If problem persists, close any applications accessing the database:
   ```bash
   lsof ~/.music_monitor.db
   ```

### Background Process Stops Working

**Problem:** Headless mode stops detecting music after a while

**Solution:**
1. Install and use `screen` for better background support:
   ```bash
   brew install screen
   ./shamon.sh --auto-input --headless
   ```
2. Check the log file for errors:
   ```bash
   tail -f ~/.music_monitor.log
   ```
3. Use the LaunchAgent method for persistent operation
4. Ensure your Mac doesn't sleep (System Preferences > Energy Saver)

### Preferred Device Not Found

**Problem:** `Error: None of the preferred devices found.`

**Solution:**
1. List available devices without `--auto-input` to see what's available
2. Update your `~/.shamonrc` with the correct device names:
   ```bash
   ./shamon.sh  # Run interactively to see device list
   ```
3. Device names must match exactly (case-sensitive)

### No Music Detected

**Problem:** Shamon runs but doesn't detect any music

**Solution:**
1. Verify audio is being captured:
   ```bash
   ./detect_audio_level.sh
   ```
2. Check the audio threshold in your config - lower it if needed:
   ```bash
   echo "AUDIO_THRESHOLD=0.005" >> ~/.shamonrc
   ```
3. Increase your system volume
4. Ensure the correct audio device is selected
5. Try playing music from a different source
6. Check debug logs for clues:
   ```bash
   ./shamon.sh --debug
   tail -f ~/.music_monitor.log
   ```

### Permission Denied on macOS

**Problem:** Terminal doesn't have microphone access

**Solution:**
1. Go to System Preferences > Security & Privacy > Privacy > Microphone
2. Ensure Terminal.app (or iTerm2) has microphone access enabled
3. You may need to restart Terminal after granting permission

### Web Server Issues

**Problem:** `ModuleNotFoundError: No module named 'fastapi'`

**Solution:**
Install Python dependencies:
```bash
pip install -r requirements.txt
```

**Problem:** Web server shows "Database not found"

**Solution:**
Run shamon.sh at least once to create the database:
```bash
./shamon.sh --auto-input
# Let it detect at least one song, then Ctrl+C to stop
python serve.py
```

## Architecture

### Core Components

1. **Audio Capture** — Uses SoX to record 5-second samples from selected audio device
2. **Level Detection** — Calculates RMS amplitude to skip silence (threshold: 0.001)
3. **Normalization** — Boosts audio to -3dB for consistent recognition quality
4. **Recognition** — Sends normalized audio to Vibra → Shazam API
5. **Deduplication** — Title-based matching with 60-second time window
6. **Storage** — SQLite database stores timestamp, title, artist, and audio_level
7. **Interval Management** — Dynamically adjusts check frequency based on results

### Data Flow

```
Audio Device → SoX Recording → Level Check → Normalize (-3dB) → Vibra/Shazam → SQLite
                                    ↓                                              ↓
                             (Skip if silent)                          Title Matching
                                                                              ↓
                                                                 (Skip if duplicate)
```

## Files

- `shamon.sh` - Main monitoring script
- `common.sh` - Shared functions library
- `serve.py` - Web server for viewing data
- `requirements.txt` - Python dependencies
- `detect_audio_level.sh` - Audio debugging tool
- `shamon_daemon.sh` - Daemon mode runner
- `shamon_background.sh` - macOS background launcher
- `com.shamon.music-monitor.plist` - LaunchAgent configuration
- `~/.music_monitor.db` - SQLite database (created on first run)
- `~/.music_monitor.log` - Debug log file
- `~/.shamonrc` - User configuration file (optional)

## Version

Current version: **1.2.3**

### What's New

**v1.2.3** — Improved song matching and audio detection
- Audio normalization to -3dB before recognition (detects quieter music)
- Title-based matching with 60-second time window (handles artist variations)
- Lower detection threshold (0.001 RMS)
- Mic-first device fallback priority

**v1.2.2** — Performance and reliability
- Network check caching (30 seconds)
- Improved device fallback to any available device
- XSS fix in web server

**v1.2.1** — Bug fix
- Fixed parsing of multi-word song titles

**v1.2.0** — Fuzzy matching
- First-word matching for title and artist

**v1.1.0** — Major refactoring
- Security fixes (SQL injection prevention)
- Configuration file support
- Optimized audio recording

## Contributing

Issues and pull requests are welcome!

## License

Check the project repository for license information.
