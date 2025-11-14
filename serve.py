#!/usr/bin/env python3

"""
Shamon Web Server
Provides HTTP endpoints to view music recognition data from the SQLite database
"""

from fastapi import FastAPI, Response, HTTPException
from typing import List, Dict, Any
import sqlite3
import os
import uvicorn

app = FastAPI(
    title="Shamon Music Data API",
    description="Web API for viewing music recognition history",
    version="1.2.0"
)

# Database configuration
DB_PATH = os.path.expanduser("~/.music_monitor.db")


def get_db_connection():
    """Create and return a database connection"""
    if not os.path.exists(DB_PATH):
        raise HTTPException(
            status_code=503,
            detail=f"Database not found at {DB_PATH}. Run shamon.sh first to create the database."
        )
    return sqlite3.connect(DB_PATH)


def query_songs(limit: int = 100) -> List[Dict[str, Any]]:
    """Query songs from the database

    Args:
        limit: Maximum number of songs to return

    Returns:
        List of song dictionaries with timestamp, title, artist, and audio_level
    """
    conn = get_db_connection()
    conn.row_factory = sqlite3.Row
    cursor = conn.cursor()

    cursor.execute(
        """
        SELECT
            datetime(timestamp, 'localtime') as timestamp,
            title,
            artist,
            audio_level
        FROM songs
        ORDER BY timestamp DESC
        LIMIT ?
        """,
        (limit,)
    )

    rows = cursor.fetchall()
    conn.close()

    return [dict(row) for row in rows]


@app.get("/")
def root():
    """Root endpoint with API information"""
    return {
        "name": "Shamon Music Data API",
        "version": "1.2.0",
        "endpoints": {
            "/json": "Get song data as JSON",
            "/table": "Get song data as HTML table",
            "/stats": "Get database statistics"
        }
    }


@app.get("/json")
def get_music_data(limit: int = 100):
    """Get music data as JSON

    Args:
        limit: Maximum number of songs to return (default: 100)

    Returns:
        JSON array of songs
    """
    try:
        return query_songs(limit)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/stats")
def get_stats():
    """Get database statistics

    Returns:
        Statistics about the music database
    """
    try:
        conn = get_db_connection()
        cursor = conn.cursor()

        # Total songs
        cursor.execute("SELECT COUNT(*) FROM songs")
        total_songs = cursor.fetchone()[0]

        # Unique songs
        cursor.execute("SELECT COUNT(DISTINCT title || artist) FROM songs")
        unique_songs = cursor.fetchone()[0]

        # Most recent detection
        cursor.execute("SELECT datetime(MAX(timestamp), 'localtime') FROM songs")
        last_detection = cursor.fetchone()[0]

        # Most detected song
        cursor.execute(
            """
            SELECT title, artist, COUNT(*) as count
            FROM songs
            GROUP BY title, artist
            ORDER BY count DESC
            LIMIT 1
            """
        )
        top_song = cursor.fetchone()

        conn.close()

        return {
            "total_detections": total_songs,
            "unique_songs": unique_songs,
            "last_detection": last_detection,
            "most_detected": {
                "title": top_song[0] if top_song else None,
                "artist": top_song[1] if top_song else None,
                "count": top_song[2] if top_song else 0
            }
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/table")
def get_music_table(limit: int = 100):
    """Get music data as cyberpunk-styled HTML table

    Args:
        limit: Maximum number of songs to return (default: 100)

    Returns:
        HTML page with song data in a table
    """
    try:
        data = query_songs(limit)
    except Exception as e:
        return Response(
            content=f"<html><body><h1>Error</h1><p>{str(e)}</p></body></html>",
            media_type="text/html"
        )

    # Create HTML table
    html = """
    <!DOCTYPE html>
    <html>
    <head>
        <title>Shamon - Music Data</title>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
            body {
                background-color: #0a0a0f;
                color: #00ff66;
                font-family: 'Courier New', monospace;
                margin: 0;
                padding: 20px;
            }
            .header {
                margin-bottom: 30px;
            }
            h1 {
                color: #ff00aa;
                text-shadow: 0 0 5px #ff00aa, 0 0 10px #ff00aa;
                text-transform: uppercase;
                letter-spacing: 2px;
                margin-bottom: 10px;
            }
            .stats {
                color: #00ccff;
                margin-bottom: 20px;
            }
            table {
                border-collapse: collapse;
                width: 100%;
                background-color: rgba(10, 10, 15, 0.8);
                border: 1px solid #00ccff;
                box-shadow: 0 0 15px #00ccff;
            }
            th, td {
                text-align: left;
                padding: 10px;
                border: 1px solid #00ccff;
            }
            tr:nth-child(even) {
                background-color: rgba(0, 204, 255, 0.1);
            }
            tr:hover {
                background-color: rgba(255, 0, 170, 0.2);
            }
            th {
                background-color: #000033;
                color: #00ff66;
                text-transform: uppercase;
                border-bottom: 2px solid #ff00aa;
                position: sticky;
                top: 0;
            }
            .no-data {
                text-align: center;
                padding: 40px;
                color: #ff00aa;
            }
            .footer {
                margin-top: 20px;
                text-align: center;
                color: #666;
                font-size: 0.9em;
            }
        </style>
    </head>
    <body>
        <div class="header">
            <h1>📻 Shamon Music Monitor</h1>
            <div class="stats">Database: """ + DB_PATH + """</div>
        </div>
    """

    if data:
        html += """
        <table>
            <tr>
                <th>Timestamp</th>
                <th>Title</th>
                <th>Artist</th>
                <th>Audio Level</th>
            </tr>
        """

        # Add table rows
        for item in data:
            timestamp = item.get("timestamp", "")
            title = item.get("title", "")
            artist = item.get("artist", "")
            audio_level = item.get("audio_level", "")

            html += f"""
            <tr>
                <td>{timestamp}</td>
                <td>{title}</td>
                <td>{artist}</td>
                <td>{audio_level}</td>
            </tr>
            """

        html += "</table>"
    else:
        html += """
        <div class="no-data">
            <p>No music data found. Run shamon.sh to start monitoring.</p>
        </div>
        """

    html += """
        <div class="footer">
            Shamon v1.2.0 | Showing last """ + str(len(data)) + """ detections
        </div>
    </body>
    </html>
    """

    return Response(content=html, media_type="text/html")


if __name__ == "__main__":
    print("🎵 Starting Shamon Web Server...")
    print(f"📊 Database: {DB_PATH}")
    print("🌐 Server running at: http://0.0.0.0:8080")
    print("   - JSON data: http://localhost:8080/json")
    print("   - HTML table: http://localhost:8080/table")
    print("   - Statistics: http://localhost:8080/stats")
    print("\nPress Ctrl+C to stop")

    uvicorn.run(app, host="0.0.0.0", port=8080)
