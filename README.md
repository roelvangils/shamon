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

## Automatic Device Switching

When using `--auto-input`, the script now includes automatic failover between audio devices:

- If the current audio device produces zero audio levels for 3 consecutive checks, it automatically switches to the next available preferred device
- The preferred devices list (in order): "C922 Pro Stream Webcam", "MacBook Pro Microphone"
- This ensures continuous monitoring even when devices are disconnected or reconnected
- The script will cycle through all available preferred devices before giving up

This feature is especially useful for long-running sessions where USB devices might be temporarily disconnected.

