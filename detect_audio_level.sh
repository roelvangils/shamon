#!/bin/bash
# This script records a 5-second audio sample from the default Core Audio device,
# extracts the RMS amplitude using sox (with explicit raw format parameters),
# and saves a WAV file for debugging.

DURATION=5
RATE=22050
BITS=16
CHANNELS=1
AUDIO_DEVICE="default"
TEMP_FILE=$(mktemp)

echo "Recording a ${DURATION}s audio sample (raw)..."
sox -t coreaudio "$AUDIO_DEVICE" -t raw -b $BITS -e signed-integer -r $RATE -c $CHANNELS - trim 0 $DURATION >"$TEMP_FILE" 2>/dev/null

if [ $? -ne 0 ]; then
    echo "Error capturing audio sample."
    rm "$TEMP_FILE"
    exit 1
fi

FILE_SIZE=$(stat -f%z "$TEMP_FILE")
echo "Captured raw file size: $FILE_SIZE bytes"

echo "Extracting RMS amplitude..."
# Specify the raw format when processing the file so sox can interpret the data correctly.
AUDIO_STATS=$(sox -t raw -b $BITS -r $RATE -e signed-integer -c $CHANNELS "$TEMP_FILE" -n stat 2>&1)
RMS_AMPLITUDE=$(echo "$AUDIO_STATS" | tr -s ' ' | grep -i "rms amplitude" | cut -d':' -f2 | sed 's/^ *//')

if [ -z "$RMS_AMPLITUDE" ]; then
    echo "No RMS amplitude detected."
else
    echo "RMS amplitude: $RMS_AMPLITUDE"
fi

# Save a WAV file for debugging purposes
WAVE_FILE="/Users/roelvangils/Repos/shamon/debug_sample.wav"
echo "Recording a ${DURATION}s audio sample (WAV)..."
sox -t coreaudio "$AUDIO_DEVICE" "$WAVE_FILE" trim 0 $DURATION 2>/dev/null
if [ $? -eq 0 ]; then
    echo "WAV file saved to: $WAVE_FILE"
else
    echo "Failed to record WAV file."
fi

rm "$TEMP_FILE"
