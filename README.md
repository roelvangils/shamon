# What is Shamon?

This CLI tool uses Vibra for fingerprinting music that is playing on your computer and then send it to the Shazam API.

## installation

First follow [the instructions to install Vibra](https://github.com/BayernMuller/vibra) on your system.

## Usage

-   `./shamon.sh` # Normal mode with interactive device selection
-   `./shamon.sh --json` # JSON output mode
-   `./shamon.sh --debug` # Debug mode with logging
-   `./shamon.sh --auto-input` # Auto-select input device from preferred list (with automatic failover)
-   `./shamon.sh --headless` # Run in background without console output

You can combine flags:
-   `./shamon.sh --auto-input --headless` # Auto-select device and run in background

## Headless Mode

When using the `--headless` flag, the script will:
- Start in the background and immediately return control to the terminal
- Display the process ID (PID) for managing the background process
- Log all output to `~/.music_monitor.log` (or `~/.music_monitor_ram.log` for the RAM version)
- Continue monitoring music until stopped with `kill <PID>`

### macOS Audio Access in Background

On macOS, background processes may lose access to CoreAudio devices. If you experience issues with headless mode, use one of these alternatives:

#### Option 1: Screen Session (Recommended)
If `screen` is installed, the script will automatically use it to maintain audio access:
```bash
# Install screen if needed
brew install screen

$ ./shamon.sh --auto-input --headless
📻 Music Monitor started in background mode (screen session)
Screen session: shamon_12345
To view: screen -r shamon_12345
To stop: screen -S shamon_12345 -X quit
```

#### Option 2: Background Launcher
Use the provided launcher script that maintains Terminal.app context:
```bash
$ ./shamon_background.sh
```

#### Option 3: LaunchAgent (Persistent)
Install as a LaunchAgent for automatic startup:
```bash
# Copy the plist file
cp com.shamon.music-monitor.plist ~/Library/LaunchAgents/

# Load the service
launchctl load ~/Library/LaunchAgents/com.shamon.music-monitor.plist

# Stop the service
launchctl unload ~/Library/LaunchAgents/com.shamon.music-monitor.plist
```

## Automatic Device Switching

When using `--auto-input`, the script now includes automatic failover between audio devices:

- If the current audio device produces zero audio levels for 3 consecutive checks, it automatically switches to the next available preferred device
- The preferred devices list (in order): "C922 Pro Stream Webcam", "MacBook Pro Microphone"
- This ensures continuous monitoring even when devices are disconnected or reconnected
- The script will cycle through all available preferred devices before giving up

This feature is especially useful for long-running sessions where USB devices might be temporarily disconnected.

## Query History

To view the last 10 songs, execute the following command:

```bash
sqlite3 ~/.music_monitor.db "SELECT datetime(timestamp, 'localtime'), title, artist FROM songs ORDER BY timestamp DESC LIMIT 10;"
```
