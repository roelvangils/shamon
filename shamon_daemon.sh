#!/bin/bash

###########################################
# Shamon Daemon Runner
# 
# Simple daemon mode that maintains audio access
# by keeping the terminal connection alive
###########################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Trap to handle cleanup
cleanup() {
    echo "Stopping music monitor..."
    exit 0
}
trap cleanup INT TERM

echo "📻 Starting Music Monitor in daemon mode"
echo "Press Ctrl+C to stop"
echo ""

# Run with auto-input but not headless
# This keeps terminal connection for audio but suppresses interactive prompts
exec "$SCRIPT_DIR/shamon.sh" --auto-input