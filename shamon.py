#!/usr/bin/env python3
"""
Shamon - Music Recognition Monitor

A lightweight CLI tool that continuously monitors and identifies music playing
on your computer using Vibra for audio fingerprinting and the Shazam API.

Features:
- Audio normalization for better recognition
- Automatic device switching
- SQLite database storage
- Title-based deduplication
"""

import argparse
import atexit
import json
import os
import re
import select
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from datetime import datetime
from typing import Optional, List, Dict, Any

VERSION = "2.0.0"

# ANSI color codes
class Colors:
    GREEN = '\033[0;32m'
    BLUE = '\033[0;34m'
    GRAY = '\033[0;90m'
    RED = '\033[0;31m'
    YELLOW = '\033[0;33m'
    NC = '\033[0m'  # No Color


@dataclass
class Config:
    """Configuration settings"""
    duration: int = 5
    base_interval: int = 10
    max_interval: int = 60
    interval_increment: int = 5
    same_song_max_interval: int = 60
    rate: int = 22050
    bits: int = 16
    db_file: str = os.path.expanduser("~/.music_monitor.db")
    log_file: str = os.path.expanduser("~/.music_monitor.log")
    audio_threshold: float = 0.0005  # Lower threshold to catch quieter audio
    debug: bool = False
    json_output: bool = False
    auto_input: bool = False
    headless: bool = False
    preferred_devices: List[str] = None
    max_consecutive_zero_audio: int = 3
    max_recognition_retries: int = 3
    silence_interval_increment: int = 10   # Add 10s each silent check
    silence_max_interval: int = 3600       # Max 1 hour between checks

    def __post_init__(self):
        if self.preferred_devices is None:
            self.preferred_devices = []


class ShamonMonitor:
    """Main monitoring class"""

    def __init__(self, config: Config):
        self.config = config
        self.input_device: Optional[str] = None
        self.current_device_index: int = -1
        self.interval: int = config.base_interval
        self.last_song: str = ""
        self.consecutive_empty: int = 0
        self.consecutive_zero_audio: int = 0
        self.first_run: bool = True
        self.running: bool = True
        self.original_terminal_settings: Optional[str] = None
        self.temp_audio: Optional[str] = None
        self.temp_normalized: Optional[str] = None
        self.last_network_check: int = 0
        self.network_cache_duration: int = 30
        self.devices_exhausted: bool = False  # Track if all devices tried during silence
        self.clamshell_mode: bool = False     # MacBook lid closed detection

        # Create temp files (using mkstemp for security - mktemp is deprecated)
        fd, self.temp_audio = tempfile.mkstemp(suffix='.wav', prefix='shamon_audio_')
        os.close(fd)  # Close the file descriptor, we'll write via sox
        fd, self.temp_normalized = tempfile.mkstemp(suffix='.wav', prefix='shamon_normalized_')
        os.close(fd)

    def debug_log(self, message: str):
        """Log debug message to file"""
        if self.config.debug:
            timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
            with open(self.config.log_file, 'a') as f:
                f.write(f"{timestamp} DEBUG: {message}\n")

    def clear_line(self):
        """Clear current terminal line"""
        print("\r\033[K", end='', flush=True)

    # Keywords that identify built-in microphones (case-insensitive matching)
    BUILTIN_MIC_KEYWORDS = [
        'macbook pro microphone',
        'macbook air microphone',
        'built-in microphone',
        'internal microphone',
    ]

    def is_clamshell_mode(self) -> bool:
        """Check if MacBook lid is closed (macOS only).

        Uses ioreg to query AppleClamshellState. Returns False on non-macOS
        or if detection fails.
        """
        if sys.platform != 'darwin':
            return False
        try:
            result = subprocess.run(
                ['ioreg', '-r', '-k', 'AppleClamshellState'],
                capture_output=True, text=True, timeout=5
            )
            # Parse output like: "AppleClamshellState" = Yes
            for line in result.stdout.split('\n'):
                if 'AppleClamshellState' in line and '=' in line:
                    value = line.split('=')[1].strip().strip('"').lower()
                    is_clamshell = value == 'yes'
                    self.debug_log(f"Clamshell mode: {is_clamshell}")
                    return is_clamshell
        except (subprocess.SubprocessError, OSError) as e:
            self.debug_log(f"Clamshell detection failed: {e}")
        return False

    def is_builtin_mic(self, device_name: str) -> bool:
        """Check if device is a built-in microphone.

        Matches against known built-in microphone names. The built-in mic
        cannot be used when the MacBook lid is closed (clamshell mode).
        """
        return any(kw in device_name.lower() for kw in self.BUILTIN_MIC_KEYWORDS)

    def check_dependencies(self) -> bool:
        """Check for required dependencies"""
        required = ['sox', 'vibra']
        missing = []

        for cmd in required:
            try:
                subprocess.run([cmd, '--help'], capture_output=True, timeout=5)
            except (subprocess.SubprocessError, FileNotFoundError):
                # Try alternative check
                result = subprocess.run(['which', cmd], capture_output=True)
                if result.returncode != 0:
                    missing.append(cmd)

        if missing:
            if not self.config.headless:
                print(f"{Colors.RED}Error: Missing dependencies: {', '.join(missing)}{Colors.NC}")
                print("Install with: brew install " + " ".join(missing))
            return False
        return True

    def get_audio_devices(self) -> List[str]:
        """Get list of available audio input devices.

        Excludes output-only devices and built-in mic when in clamshell mode.
        """
        # Keywords that indicate output-only devices
        output_keywords = ['speaker', 'output', 'headphone']

        try:
            result = subprocess.run(
                ['sox', '-V3', '-n', '-t', 'coreaudio', 'dummy', 'trim', '0', '1'],
                capture_output=True,
                text=True,
                timeout=10
            )
            output = result.stderr + result.stdout
            devices = []
            for line in output.split('\n'):
                if 'Found Audio Device' in line:
                    match = re.search(r'"(.+)"', line)
                    if match:
                        device_name = match.group(1)
                        # Filter out output-only devices
                        if any(kw in device_name.lower() for kw in output_keywords):
                            continue
                        # Filter out built-in mic in clamshell mode
                        if self.clamshell_mode and self.is_builtin_mic(device_name):
                            self.debug_log(f"Excluding built-in mic in clamshell mode: {device_name}")
                            continue
                        devices.append(device_name)
            return devices
        except subprocess.SubprocessError as e:
            self.debug_log(f"Error getting audio devices: {e}")
            return []

    def select_device(self, devices: List[str]) -> Optional[str]:
        """Select audio input device"""
        if self.config.auto_input:
            # Auto-select from preferred list
            for i, preferred in enumerate(self.config.preferred_devices):
                if preferred in devices:
                    self.current_device_index = i
                    self.debug_log(f"Auto-selected device: {preferred}")
                    if not self.config.headless:
                        print(f"{Colors.BLUE}Auto-selected input device: {preferred}{Colors.NC}")
                    return preferred

            # Fallback: prioritize devices with 'mic' in name
            mic_devices = [d for d in devices if 'mic' in d.lower()]
            if mic_devices:
                device = mic_devices[0]
                self.debug_log(f"Fallback to mic device: {device}")
                if not self.config.headless:
                    print(f"{Colors.BLUE}Auto-selected input device: {device}{Colors.NC}")
                return device

            if not self.config.headless:
                print(f"{Colors.RED}Error: None of the preferred devices found.{Colors.NC}")
                print(f"{Colors.RED}Available devices:{Colors.NC}")
                for d in devices:
                    print(f"  - {d}")
            return None
        else:
            # Interactive selection
            print(f"{Colors.BLUE}Available audio input devices:{Colors.NC}")
            for i, device in enumerate(devices, 1):
                print(f"{i:2d}) {device}")

            while True:
                try:
                    choice = input(f"Enter the number of the input device to use (1-{len(devices)}): ")
                    idx = int(choice) - 1
                    if 0 <= idx < len(devices):
                        print(f"{Colors.BLUE}Using input device: {devices[idx]}{Colors.NC}")
                        return devices[idx]
                    else:
                        print(f"{Colors.RED}Invalid selection. Please enter a number between 1 and {len(devices)}{Colors.NC}")
                except ValueError:
                    print(f"{Colors.RED}Invalid input. Please enter a number.{Colors.NC}")
                except EOFError:
                    return None

    def switch_audio_device(self) -> bool:
        """Switch to next available audio device"""
        self.debug_log("Attempting to switch audio device due to zero audio levels")

        devices = self.get_audio_devices()
        if not devices:
            self.debug_log("No audio devices found during switch attempt")
            return False

        # Try preferred devices first
        start_idx = self.current_device_index + 1
        for i in range(start_idx, len(self.config.preferred_devices)):
            if self.config.preferred_devices[i] in devices:
                self.input_device = self.config.preferred_devices[i]
                self.current_device_index = i
                self.debug_log(f"Switched to device: {self.input_device}")
                if not self.config.headless and not self.config.json_output:
                    print(f"\n{Colors.YELLOW}Audio device switched to: {self.input_device}{Colors.NC}")
                return True

        # Wrap around
        for i in range(0, start_idx):
            if self.config.preferred_devices[i] in devices:
                self.input_device = self.config.preferred_devices[i]
                self.current_device_index = i
                self.debug_log(f"Switched to device (wrapped): {self.input_device}")
                return True

        # Last resort: prioritize devices with 'mic' in name
        mic_devices = [d for d in devices if 'mic' in d.lower() and d != self.input_device]
        other_devices = [d for d in devices if 'mic' not in d.lower() and d != self.input_device]
        sorted_devices = mic_devices + other_devices

        for device in sorted_devices:
            self.input_device = device
            self.current_device_index = -1
            self.debug_log(f"Falling back to available device: {self.input_device}")
            if not self.config.headless and not self.config.json_output:
                print(f"\n{Colors.YELLOW}Audio device switched to: {self.input_device}{Colors.NC}")
            return True

        self.debug_log("No alternative device found")
        return False

    def check_network(self) -> bool:
        """Check network connectivity with caching"""
        now = int(time.time())
        if now - self.last_network_check < self.network_cache_duration:
            return True

        try:
            result = subprocess.run(
                ['ping', '-c', '1', '-W', '2', '8.8.8.8'],
                capture_output=True,
                timeout=5
            )
            if result.returncode == 0:
                self.last_network_check = now
                return True
        except subprocess.SubprocessError:
            pass

        if not self.config.json_output and not self.config.headless:
            self.clear_line()
            print(f"{Colors.RED}Network unavailable, waiting...{Colors.NC}", end='')
        self.debug_log("Network unavailable")
        self.last_network_check = 0
        return False

    def init_database(self):
        """Initialize SQLite database"""
        with sqlite3.connect(self.config.db_file) as conn:
            conn.execute("""
                CREATE TABLE IF NOT EXISTS songs (
                    id INTEGER PRIMARY KEY,
                    timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
                    title TEXT,
                    artist TEXT,
                    audio_level REAL
                )
            """)

    def record_audio(self) -> bool:
        """Record audio sample"""
        try:
            result = subprocess.run([
                'sox', '-t', 'coreaudio', self.input_device,
                '-b', str(self.config.bits),
                '-e', 'signed-integer',
                '-r', str(self.config.rate),
                '-c', '1',
                self.temp_audio,
                'trim', '0', str(self.config.duration)
            ], capture_output=True, timeout=30)

            if result.returncode != 0 or not os.path.exists(self.temp_audio):
                self.debug_log(f"Failed to record audio from {self.input_device}")
                return False
            return True
        except subprocess.SubprocessError as e:
            self.debug_log(f"Recording error: {e}")
            return False

    def get_audio_level(self, audio_file: Optional[str] = None) -> float:
        """Get RMS audio level from audio file"""
        if audio_file is None:
            audio_file = self.temp_audio
        try:
            result = subprocess.run(
                ['sox', '-t', 'wav', audio_file, '-n', 'stat'],
                capture_output=True,
                text=True,
                timeout=10
            )
            output = result.stderr

            for line in output.split('\n'):
                if 'RMS' in line and 'amplitude' in line:
                    parts = line.split()
                    if len(parts) >= 3:
                        level_str = parts[-1].replace(',', '.')
                        try:
                            return float(level_str)
                        except ValueError:
                            pass

            self.debug_log("RMS amplitude not found, defaulting to 0.0")
            return 0.0
        except subprocess.SubprocessError as e:
            self.debug_log(f"Error getting audio level: {e}")
            return 0.0

    def normalize_audio(self) -> bool:
        """Normalize audio to 0dB (maximum volume without clipping)"""
        try:
            result = subprocess.run([
                'sox', self.temp_audio, self.temp_normalized, 'norm', '0'
            ], capture_output=True, timeout=30)
            if result.returncode != 0:
                self.debug_log(f"Normalization failed: {result.stderr.decode()}")
                return False
            if not os.path.exists(self.temp_normalized):
                self.debug_log("Normalization failed: output file not created")
                return False
            return True
        except subprocess.SubprocessError as e:
            self.debug_log(f"Normalization error: {e}")
            return False

    def call_vibra_api(self) -> Optional[Dict[str, Any]]:
        """Call Vibra for song recognition"""
        try:
            # Convert to raw PCM and pipe to vibra
            sox_cmd = [
                'sox', '-t', 'wav', self.temp_normalized,
                '-t', 'raw', '-b', str(self.config.bits),
                '-e', 'signed-integer', '-r', str(self.config.rate),
                '-c', '1', '-'
            ]
            vibra_cmd = [
                'vibra', '--recognize',
                '--seconds', str(self.config.duration),
                '--rate', str(self.config.rate),
                '--channels', '1',
                '--bits', str(self.config.bits)
            ]

            sox_proc = subprocess.Popen(sox_cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            vibra_proc = subprocess.Popen(
                vibra_cmd,
                stdin=sox_proc.stdout,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL if self.config.headless else None
            )
            sox_proc.stdout.close()

            output, _ = vibra_proc.communicate(timeout=60)

            if vibra_proc.returncode != 0:
                return None

            result = json.loads(output.decode())
            return result
        except (subprocess.SubprocessError, json.JSONDecodeError) as e:
            self.debug_log(f"Vibra API error: {e}")
            return None

    def recognize_audio(self) -> Optional[Dict[str, Any]]:
        """Recognize song using Vibra/Shazam API"""
        result = self.call_vibra_api()

        if result and result.get('track'):
            title = result['track'].get('title', '')
            artist = result['track'].get('subtitle', '')

            # Remove parenthetical content from title
            title = re.sub(r'\s*\(.*\)', '', title)

            return {
                'title': title,
                'artist': artist
            }

        return None

    def normalize_title(self, title: str) -> str:
        """Normalize title for matching.

        Handles variations like:
        - 'Fly' vs 'Fly - Through the Starry Night' (subtitle after dash)
        - 'Fastlove, Pt. 1' vs 'Fastlove' (part numbers)
        """
        # Remove everything after dash/colon (subtitles, versions)
        cleaned = re.sub(r'\s*[-–—:]\s.*$', '', title)
        # Remove part/version indicators (Pt. 1, Part 2, etc.)
        cleaned = re.sub(r',?\s*(pt\.?|part)\s*\d+', '', cleaned, flags=re.IGNORECASE)
        # Remove punctuation and lowercase
        cleaned = re.sub(r'[,\'"!?.]', '', cleaned.lower())
        # Take first 3 words
        words = cleaned.split()[:3]
        return ' '.join(words)

    def save_song(self, title: str, artist: str, audio_level: float):
        """Save song to database"""
        try:
            with sqlite3.connect(self.config.db_file) as conn:
                conn.execute("""
                    INSERT INTO songs (timestamp, title, artist, audio_level)
                    VALUES (datetime('now', 'localtime'), ?, ?, ?)
                """, (title, artist, audio_level))
        except sqlite3.Error as e:
            self.debug_log(f"Database error: {e}")

    def wait_with_countdown(self):
        """Wait with interactive countdown (press Enter to skip)"""
        if self.config.json_output or self.config.headless:
            time.sleep(self.interval)
            return

        for i in range(self.interval, 0, -1):
            self.clear_line()
            dots = '.' * (i % 4)
            print(f"{Colors.GRAY}Next check in {i:2d}s (press Enter to skip) {dots}{Colors.NC}", end='', flush=True)

            # Check for Enter key (non-blocking)
            if sys.stdin in select.select([sys.stdin], [], [], 1)[0]:
                sys.stdin.readline()
                self.clear_line()
                # Reset interval to base when user manually skips
                self.interval = self.config.base_interval
                self.devices_exhausted = False  # Allow device switching again
                print(f"{Colors.YELLOW}Skipping wait, interval reset to {self.interval}s{Colors.NC}")
                return

    def cleanup(self):
        """Clean up resources"""
        self.debug_log("Cleanup initiated")
        self.running = False

        # Remove temp files
        for f in [self.temp_audio, self.temp_normalized]:
            if f and os.path.exists(f):
                try:
                    os.remove(f)
                except OSError:
                    pass

        # Restore terminal
        if self.original_terminal_settings:
            try:
                subprocess.run(['stty', self.original_terminal_settings], capture_output=True)
            except (OSError, subprocess.SubprocessError):
                pass

        # Show summary
        if not self.config.json_output and not self.config.headless:
            try:
                with sqlite3.connect(self.config.db_file) as conn:
                    total = conn.execute("SELECT COUNT(*) FROM songs").fetchone()[0]
                print(f"\n{Colors.BLUE}Monitor stopped. Detected {total} songs{Colors.NC}")
            except sqlite3.Error:
                pass

        self.debug_log("Cleanup completed")

    def run(self):
        """Main monitoring loop"""
        # Check dependencies
        if not self.check_dependencies():
            return 1

        # Check clamshell mode (macOS only)
        self.clamshell_mode = self.is_clamshell_mode()
        if self.clamshell_mode and not self.config.headless:
            print(f"{Colors.YELLOW}Built-in microphone cannot be used because the MacBook lid is closed.{Colors.NC}")

        # Get and select audio device
        devices = self.get_audio_devices()
        if not devices:
            if not self.config.headless:
                print(f"{Colors.RED}No input devices found.{Colors.NC}")
            return 1

        self.input_device = self.select_device(devices)
        if not self.input_device:
            return 1

        # Initialize database
        self.init_database()

        # Set up signal handlers and atexit
        atexit.register(self.cleanup)

        def handle_signal(sig, frame):
            if self.running:  # Only cleanup once
                atexit.unregister(self.cleanup)  # Prevent double cleanup
                self.cleanup()
                sys.exit(0)
        signal.signal(signal.SIGINT, handle_signal)
        signal.signal(signal.SIGTERM, handle_signal)

        # Store terminal settings
        if not self.config.headless:
            try:
                result = subprocess.run(['stty', '-g'], capture_output=True, text=True)
                self.original_terminal_settings = result.stdout.strip()
            except (OSError, subprocess.SubprocessError):
                pass

        # Log session start (append mode preserves history)
        if self.config.debug:
            with open(self.config.log_file, 'a') as f:
                f.write(f"\n{'=' * 50}\n")
                f.write(f"Session started: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
                f.write(f"{'=' * 50}\n")

        # Show startup message
        if not self.config.json_output and not self.config.headless:
            print(f"{Colors.GREEN}📻 Music Monitor Started v{VERSION}{Colors.NC} (Press Ctrl+C to stop)")
            print(f"Recording {self.config.duration}s samples every {self.interval}s")

        # Main loop
        while self.running:
            loop_start = time.time()

            # Wait between checks
            if not self.first_run:
                self.wait_with_countdown()
            self.first_run = False

            # Check network
            if not self.check_network():
                time.sleep(30)
                continue

            # Record audio
            if not self.record_audio():
                if self.switch_audio_device():
                    self.consecutive_zero_audio = 0
                    continue
                else:
                    if not self.config.json_output and not self.config.headless:
                        self.clear_line()
                        print(f"{Colors.RED}Audio recording failed. Check device connection.{Colors.NC}")
                    time.sleep(10)
                    continue

            # Get audio level
            audio_level = self.get_audio_level()
            self.debug_log(f"Audio level: {audio_level} (threshold: {self.config.audio_threshold})")

            # Check if too quiet
            if audio_level < self.config.audio_threshold:
                self.debug_log(f"Audio level too low ({audio_level}), skipping recognition")

                # Try switching devices once when zero audio detected
                if audio_level < 0.0001:  # Effectively zero
                    self.consecutive_zero_audio += 1
                    self.debug_log(f"Zero audio level (count: {self.consecutive_zero_audio})")

                    if self.consecutive_zero_audio >= self.config.max_consecutive_zero_audio:
                        if not self.devices_exhausted:
                            if self.switch_audio_device():
                                self.consecutive_zero_audio = 0
                                continue  # Try new device immediately
                            else:
                                self.devices_exhausted = True
                                self.debug_log("All devices tried, entering silence backoff mode")
                        self.consecutive_zero_audio = 0
                else:
                    self.consecutive_zero_audio = 0

                # Silence backoff: gradually increase interval up to max
                self.interval = min(
                    self.interval + self.config.silence_interval_increment,
                    self.config.silence_max_interval
                )
                self.debug_log(f"Silence detected, next check in {self.interval}s")
                continue

            # Audio detected - reset everything
            self.consecutive_zero_audio = 0
            self.devices_exhausted = False
            self.interval = self.config.base_interval

            # Normalize audio
            if not self.normalize_audio():
                self.debug_log("Audio normalization failed")
                continue

            if self.config.debug:
                normalized_level = self.get_audio_level(self.temp_normalized)
                self.debug_log(f"Audio normalized: RMS {audio_level:.4f} → {normalized_level:.4f}")

            # Recognize song
            result = self.recognize_audio()

            if result:
                title = result['title']
                artist = result['artist']
                song_info = f"{title} by {artist}"
                timestamp = datetime.now().strftime('%H:%M:%S')
                title_normalized = self.normalize_title(title)

                # Only log if different song (never log same song twice in a row)
                if self.last_song != title_normalized:
                    self.interval = self.config.base_interval
                    self.last_song = title_normalized
                    self.debug_log(f"New song detected: {song_info}")

                    if self.config.json_output:
                        output = {
                            'timestamp': timestamp,
                            'title': title,
                            'artist': artist,
                            'audio_level': audio_level
                        }
                        print(json.dumps(output))
                    elif not self.config.headless:
                        self.clear_line()
                        print(f"{Colors.GREEN}[{timestamp}] {song_info}{Colors.NC}")

                    # Save to database
                    self.save_song(title, artist, audio_level)
                else:
                    # Same song, increase interval
                    self.interval = min(
                        self.interval + self.config.interval_increment,
                        self.config.same_song_max_interval
                    )
                    self.debug_log(f"Same song detected (title: {title_normalized}), interval increased to {self.interval}")

                self.consecutive_empty = 0
            else:
                # No track found
                self.consecutive_empty += 1
                self.interval = min(
                    self.config.base_interval * self.consecutive_empty,
                    self.config.max_interval
                )
                self.debug_log(f"No track found (attempt {self.consecutive_empty})")

            # Show "No music detected" message
            if self.consecutive_empty >= self.config.max_recognition_retries:
                if not self.config.json_output and not self.config.headless:
                    self.clear_line()
                    print(f"{Colors.GRAY}No music detected{Colors.NC}", end='', flush=True)
                self.consecutive_empty = 0

            # Safety check for headless mode
            if self.config.headless:
                loop_duration = time.time() - loop_start
                if loop_duration < 5:
                    time.sleep(5 - loop_duration)

        return 0


def load_config_file(config: Config) -> Config:
    """Load configuration from ~/.shamonrc if it exists"""
    config_path = os.path.expanduser("~/.shamonrc")
    if not os.path.exists(config_path):
        return config

    try:
        with open(config_path, 'r') as f:
            content = f.read()

        # Parse bash-style config
        lines = content.split('\n')
        i = 0
        while i < len(lines):
            line = lines[i].strip()
            if not line or line.startswith('#'):
                i += 1
                continue

            if '=' in line:
                key, value = line.split('=', 1)
                key = key.strip()
                value = value.strip()

                if key == 'PREFERRED_DEVICES' and value.startswith('('):
                    # Parse bash array (can span multiple lines)
                    devices = []
                    array_content = value[1:]  # Skip opening paren
                    while ')' not in array_content and i < len(lines) - 1:
                        i += 1
                        array_content += ' ' + lines[i].strip()

                    # Extract quoted strings
                    for match in re.finditer(r'"([^"]+)"', array_content):
                        devices.append(match.group(1))
                    if devices:
                        config.preferred_devices = devices
                else:
                    value = value.strip('"').strip("'")
                    if key == 'AUDIO_THRESHOLD':
                        config.audio_threshold = float(value)
                    elif key == 'BASE_INTERVAL':
                        config.base_interval = int(value)
                    elif key == 'MAX_INTERVAL':
                        config.max_interval = int(value)
                    elif key == 'DEBUG' and value.lower() == 'true':
                        config.debug = True

            i += 1

    except (IOError, ValueError):
        pass  # Silently ignore config errors

    return config


def main():
    parser = argparse.ArgumentParser(
        description=f'Shamon v{VERSION} - Music Recognition Monitor',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
    shamon.py                     # Interactive mode
    shamon.py --auto-input        # Auto-select device
    shamon.py --auto-input --headless  # Background mode
    shamon.py --json              # JSON output mode

Configuration:
    Create ~/.shamonrc to customize settings.

Database:
    Songs are stored in: ~/.music_monitor.db
        """
    )
    parser.add_argument('--json', action='store_true', help='Output in JSON format')
    parser.add_argument('--debug', action='store_true', help='Enable debug logging')
    parser.add_argument('--auto-input', action='store_true', help='Auto-select input device')
    parser.add_argument('--headless', action='store_true', help='Run in background')
    parser.add_argument('--version', action='version', version=f'Shamon v{VERSION}')

    args = parser.parse_args()

    # Load config file first, then apply CLI args (CLI takes precedence)
    config = Config()
    config = load_config_file(config)

    # CLI args override config file
    if args.debug:
        config.debug = True
    if args.json:
        config.json_output = True
    if args.auto_input:
        config.auto_input = True
    if args.headless:
        config.headless = True

    monitor = ShamonMonitor(config)
    return monitor.run()


if __name__ == '__main__':
    sys.exit(main())
