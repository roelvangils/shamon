# Usage

-   `./script.sh` # Normal mode with debug info
-   `./script.sh --json` # JSON output mode
-   `./script.sh --debug` # Debug mode

## Query History

To view the last 10 songs, execute the following command:

```bash
sqlite3 ~/.music_monitor.db "SELECT datetime(timestamp, 'localtime'), title, artist FROM songs ORDER BY timestamp DESC LIMIT 10;"
```
