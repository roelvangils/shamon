#!/bin/bash

###########################################
# Shamon Automator Launcher
# 
# Launches shamon in Terminal.app to maintain
# CoreAudio access, then exits for Automator
###########################################

# Use AppleScript to launch in Terminal
osascript <<EOF
tell application "Terminal"
    -- Close any existing shamon windows
    set shamonWindows to {}
    repeat with w in windows
        try
            if name of w contains "shamon_daemon" then
                close w
            end if
        end try
    end repeat
    
    -- Launch new instance
    do script "cd /Users/roelvangils/repos/shamon && ./shamon_daemon.sh"
    
    -- Minimize the window
    set miniaturized of front window to true
    
    -- Optional: Hide Terminal app completely
    -- set visible to false
end tell
EOF

# Exit immediately so Automator completes
echo "Shamon launched in Terminal (minimized)"
exit 0