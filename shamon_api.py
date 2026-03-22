#!/usr/bin/env python3
"""
Shamon Lightweight API - Zero dependencies song API server.

Usage:
    python shamon_api.py              # Start server on port 8888
    curl localhost:8888               # Get current song
    curl localhost:8888?offset=1      # Get previous song
"""

import json
import os
import sqlite3
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

DB_PATH = os.path.expanduser("~/.music_monitor.db")
PORT = 8888


class SongHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        # Parse query string
        query = parse_qs(urlparse(self.path).query)
        offset = abs(int(query.get("offset", [0])[0]))  # abs() handles -1, -2, etc.

        # Query database
        try:
            conn = sqlite3.connect(DB_PATH)
            cursor = conn.execute(
                """
                SELECT datetime(timestamp, 'localtime') as timestamp, title, artist
                FROM songs ORDER BY timestamp DESC LIMIT 1 OFFSET ?
                """,
                (offset,),
            )
            row = cursor.fetchone()
            conn.close()

            if row:
                response = {"timestamp": row[0], "title": row[1], "artist": row[2]}
            else:
                response = {"error": "No song found"}

        except sqlite3.Error as e:
            response = {"error": str(e)}

        # Send response
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(json.dumps(response, ensure_ascii=False).encode())

    def log_message(self, format, *args):
        pass  # Suppress request logging


def find_available_port(start_port: int, max_attempts: int = 10) -> int:
    """Find an available port starting from start_port."""
    import socket
    for port in range(start_port, start_port + max_attempts):
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
                s.bind(("", port))
                return port
        except OSError:
            continue
    raise RuntimeError(f"No available port found in range {start_port}-{start_port + max_attempts}")


if __name__ == "__main__":
    port = find_available_port(PORT)
    if port != PORT:
        print(f"Port {PORT} in use, using {port} instead")
    print(f"Shamon API running on http://localhost:{port}")
    print(f"  GET /          → Current song")
    print(f"  GET /?offset=1 → Previous song")
    HTTPServer(("", port), SongHandler).serve_forever()
