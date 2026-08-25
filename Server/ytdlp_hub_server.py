#!/usr/bin/env python3
"""Companion extraction server for the YTDLP Hub iOS app.

iOS apps cannot run yt-dlp: it is a command line program, and the platform does
not let an app spawn subprocesses or execute downloaded code. This script runs
yt-dlp somewhere that can -- a Mac, a Raspberry Pi, a home server -- and exposes
the one thing the app needs from it: the list of direct media URLs behind a
link. The app then downloads those URLs itself.

Nothing is downloaded or stored here; extraction only.

    pip install yt-dlp
    python3 ytdlp_hub_server.py --port 8420

Then in the app: Settings -> yt-dlp bridge -> http://<this-machine>:8420

Endpoints
    GET /health                 liveness plus the yt-dlp version in use
    GET /resolve?url=<link>     metadata and formats for one video

Set YTDLP_HUB_TOKEN to require `Authorization: Bearer <token>` on requests.
This server has no TLS and no rate limiting; run it on a network you trust, or
put it behind a reverse proxy.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

try:
    import yt_dlp
except ImportError:  # pragma: no cover - guidance for first run
    sys.exit("yt-dlp is not installed. Run: pip install yt-dlp")

TOKEN = os.environ.get("YTDLP_HUB_TOKEN", "")

# Only the keys the app reads. Trimming the response keeps it small -- yt-dlp's
# full info dict for a popular video is several hundred kilobytes.
INFO_KEYS = (
    "id",
    "title",
    "channel",
    "uploader",
    "duration",
    "thumbnail",
    "webpage_url",
    "is_live",
)

FORMAT_KEYS = (
    "format_id",
    "url",
    "ext",
    "vcodec",
    "acodec",
    "height",
    "width",
    "fps",
    "tbr",
    "abr",
    "filesize",
    "filesize_approx",
    "format_note",
    "asr",
    "protocol",
)

YDL_OPTIONS = {
    "quiet": True,
    "no_warnings": True,
    "noplaylist": True,
    "skip_download": True,
    # The app muxes with AVFoundation, which only understands MPEG-4 tracks,
    # but sending everything lets it decide.
    "youtube_include_dash_manifest": True,
}


def extract(url: str) -> dict:
    with yt_dlp.YoutubeDL(YDL_OPTIONS) as ydl:
        info = ydl.extract_info(url, download=False)
        info = ydl.sanitize_info(info)

    # A playlist link resolves to its first entry rather than failing.
    if info.get("_type") == "playlist":
        entries = [entry for entry in (info.get("entries") or []) if entry]
        if not entries:
            raise ValueError("That playlist has no playable entries.")
        info = entries[0]

    payload = {key: info.get(key) for key in INFO_KEYS}
    payload["formats"] = [
        {key: fmt.get(key) for key in FORMAT_KEYS}
        for fmt in (info.get("formats") or [])
        if fmt.get("url")
    ]
    return payload


class Handler(BaseHTTPRequestHandler):
    server_version = "YTDLPHub/1.0"

    def do_GET(self) -> None:  # noqa: N802 - required by BaseHTTPRequestHandler
        parsed = urlparse(self.path)

        if parsed.path == "/health":
            self.send_json(200, {"ok": True, "yt_dlp_version": yt_dlp.version.__version__})
            return

        if parsed.path != "/resolve":
            self.send_json(404, {"error": "Unknown endpoint."})
            return

        if not self.authorized():
            self.send_json(401, {"error": "Missing or invalid access token."})
            return

        url = (parse_qs(parsed.query).get("url") or [""])[0]
        if not url:
            self.send_json(400, {"error": "Pass a link as ?url=..."})
            return

        try:
            self.send_json(200, extract(url))
        except yt_dlp.utils.DownloadError as error:
            self.send_json(422, {"error": str(error).replace("ERROR: ", "", 1)})
        except Exception as error:  # noqa: BLE001 - report anything to the client
            self.send_json(500, {"error": str(error)})

    def authorized(self) -> bool:
        if not TOKEN:
            return True
        header = self.headers.get("Authorization", "")
        return header == f"Bearer {TOKEN}"

    def send_json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8420)
    args = parser.parse_args()

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"yt-dlp {yt_dlp.version.__version__} listening on http://{args.host}:{args.port}")
    if not TOKEN:
        print("No YTDLP_HUB_TOKEN set - anyone on this network can use the server.")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopping.")
        server.server_close()


if __name__ == "__main__":
    main()
