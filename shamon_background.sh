#!/bin/bash

###########################################
# Shamon Background Launcher
# 
# This script launches shamon in a way that maintains
# audio access on macOS by using Terminal.app
###########################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check if running on macOS
if [[ "$(uname)" == "Darwin" ]]; then
    # Use osascript to launch in Terminal with audio access maintained
    osascript <<EOF
tell application "Terminal"
    do script "cd '$SCRIPT_DIR' && ./shamon.sh --auto-input --headless"
    set miniaturized of front window to true
end tell
EOF
    echo "📻 Music Monitor launched in Terminal (minimized)"
    echo "Check Terminal.app to see the process"
else
    # On Linux, use the regular headless mode
    "$SCRIPT_DIR/shamon.sh" --auto-input --headless
fi