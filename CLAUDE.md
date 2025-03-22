# Shamon Project Guidelines

## Commands
- Run the main script: `./shamon.sh`
- Run RAM-optimized version: `./shamon_ram.sh`
- Debug audio detection: `./detect_audio_level.sh`
- Check recognition history: `sqlite3 ~/.music_monitor.db "SELECT datetime(timestamp, 'localtime'), title, artist FROM songs ORDER BY timestamp DESC LIMIT 10;"`

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
- Test audio capture on different systems
- Validate audio processing before song recognition
- Consider network connectivity in implementation
- Ensure proper SQLite database access