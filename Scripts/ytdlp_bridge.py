"""In-process bridge between the app and yt-dlp.

Copied into the bundled `python-packages` directory by `Scripts/fetch-python.sh`
and imported by `YTDLPBridge.m` through the embedded CPython runtime.

Two rules shape this module:

* **Never raise.** Exceptions crossing the C boundary lose their message, so
  every entry point returns a JSON string and reports problems as an `error`
  key. The Swift side treats that as a resolve failure.
* **Never write to the bundle.** The app bundle is read-only on iOS, so
  bytecode caching, yt-dlp's own cache, and archive files are all disabled.

The payload shape matches `Server/ytdlp_hub_server.py` so that the embedded and
remote resolvers decode through the same Swift type.
"""

from __future__ import annotations

import json
import os

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


def _prepare_certificates() -> None:
    """Point OpenSSL at a CA bundle.

    iOS has no /etc/ssl, so Python's default certificate lookup finds nothing
    and every HTTPS request fails verification. certifi ships its own bundle;
    `fetch-python.sh` installs it alongside yt-dlp.
    """
    try:
        import certifi
    except ImportError:
        return
    where = certifi.where()
    os.environ.setdefault("SSL_CERT_FILE", where)
    os.environ.setdefault("REQUESTS_CA_BUNDLE", where)


def _options() -> dict:
    return {
        "quiet": True,
        "no_warnings": True,
        "noplaylist": True,
        "skip_download": True,
        "no_color": True,
        # The bundle is read-only, and there is no ffmpeg to check for.
        "cachedir": False,
        "check_formats": False,
    }


def resolve(url: str) -> str:
    """Return metadata and direct media URLs for `url`, as a JSON string."""
    _prepare_certificates()

    try:
        from yt_dlp import YoutubeDL
    except Exception as exc:  # noqa: BLE001 - surfaced to the user verbatim
        return json.dumps({"error": "The bundled yt-dlp could not be loaded: %s" % exc})

    try:
        with YoutubeDL(_options()) as ydl:
            info = ydl.sanitize_info(ydl.extract_info(url, download=False))
    except Exception as exc:  # noqa: BLE001 - yt-dlp raises many error types
        message = str(exc)
        if message.startswith("ERROR: "):
            message = message[len("ERROR: "):]
        return json.dumps({"error": message})

    if not info:
        return json.dumps({"error": "yt-dlp found nothing behind that link."})

    # A playlist link resolves to its first entry rather than failing.
    if info.get("_type") == "playlist":
        entries = [entry for entry in (info.get("entries") or []) if entry]
        if not entries:
            return json.dumps({"error": "That playlist has no playable entries."})
        info = entries[0]

    payload = {key: info.get(key) for key in INFO_KEYS}
    payload["formats"] = [
        {key: fmt.get(key) for key in FORMAT_KEYS}
        for fmt in (info.get("formats") or [])
        if fmt.get("url")
    ]
    return json.dumps(payload)


def version() -> str:
    """Return the bundled yt-dlp version, as JSON."""
    try:
        from yt_dlp.version import __version__
    except Exception as exc:  # noqa: BLE001
        return json.dumps({"error": str(exc)})
    return json.dumps({"version": __version__})
