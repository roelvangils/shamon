# Save as serve_music_fastapi.py
from fastapi import FastAPI, Response
import subprocess
import json
import uvicorn

app = FastAPI(title="Music Data API")

@app.get("/json")
def get_music_data():
    result = subprocess.run(['muzak'], capture_output=True, text=True)
    jq_result = subprocess.run(['jq'], input=result.stdout, capture_output=True, text=True)
    return json.loads(jq_result.stdout)

@app.get("/table")
def get_music_table():
    # Get the same data used in the JSON endpoint
    data = get_music_data()

    # Create HTML table
    html = """
    <!DOCTYPE html>
    <html>
    <head>
        <title>Music Data</title>
        <style>
            table {
                font: 12px system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
                border-collapse: collapse;
                width: 100%;
            }
            th, td {
                text-align: left;
                padding: 8px;
                border: 1px solid #ddd;
            }
            tr:nth-child(even) {
                background-color: #f2f2f2;
            }
            th {
                background-color: #4CAF50;
                color: white;
            }
        </style>
    </head>
    <body>
        <h1>Music Data</h1>
        <table>
            <tr>
    """

    # Get table headers from the first item's keys
    if data and isinstance(data, list) and len(data) > 0:
        keys = data[0].keys()
        for key in keys:
            html += f"<th>{key}</th>"

        html += "</tr>"

        # Add table rows
        for item in data:
            html += "<tr>"
            for key in keys:
                value = item.get(key, "")
                html += f"<td>{value}</td>"
            html += "</tr>"

    html += """
        </table>
    </body>
    </html>
    """

    return Response(content=html, media_type="text/html")

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=1979)
