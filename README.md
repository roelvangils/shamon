# What is Shamon?

This CLI tool uses Vibra for fingerprinting music that is playing on your computer and then send it to the Shazam API.

## installation

First follow [the instructions to install Vibra](https://github.com/BayernMuller/vibra) on your system.

## Usage

-   `./script.sh` # Normal mode with debug info
-   `./script.sh --json` # JSON output mode
-   `./script.sh --debug` # Debug mode

## Query History

To view the last 10 songs, execute the following command:

```bash
sqlite3 ~/.music_monitor.db "SELECT datetime(timestamp, 'localtime'), title, artist FROM songs ORDER BY timestamp DESC LIMIT 10;"
```
