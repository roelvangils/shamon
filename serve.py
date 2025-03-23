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
            body {
                background-color: #0a0a0f;
                color: #00ff66;
                font-family: 'Courier New', monospace;
                margin: 0;
                padding: 20px;
            }
            h1 {
                color: #ff00aa;
                text-shadow: 0 0 5px #ff00aa, 0 0 10px #ff00aa;
                text-transform: uppercase;
                letter-spacing: 2px;
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
    uvicorn.run(app, host="127.0.0.1", port=8000)
