# YTDLP Hub

A native iOS app for saving YouTube videos to your device. Paste a link, pick a
quality, and the video downloads into the app's library where it plays offline.

Built with SwiftUI, targeting iOS 17 and later, iPhone and iPad.

## Three ways to get the media URLs

yt-dlp is a command line program, and iOS does not let an app spawn
subprocesses or execute downloaded code. So you cannot ship the yt-dlp
*binary* and run it.

You can, however, **import yt-dlp as a library**. It is pure Python, so an
embedded CPython interpreter that ships inside the app bundle — signed as part
of the app, like any other framework — can import it and call it directly.
That is roughly how a-Shell ships Python, and it is why yt-dlp already runs on
iOS today.

The app has three resolvers and falls through them in order:

| | Bundled yt-dlp | yt-dlp bridge | Built-in extractor |
|---|---|---|---|
| Where extraction runs | In the app, on device | A machine you run | In the app, on device |
| Setup | One script before building | Run one Python script | None |
| Sites | Everything yt-dlp supports | Everything yt-dlp supports | YouTube only |
| Updating | Re-run script, rebuild | `pip install -U yt-dlp` | Needs an app update |
| Adds to app size | ~40–60 MB | Nothing | Nothing |

**Bundled yt-dlp** (`Services/EmbeddedPython/`) is the default and the one to
prefer. `Scripts/fetch-python.sh` vendors a CPython runtime plus yt-dlp's
source into the project; `YTDLPBridge.m` boots the interpreter and calls
`ytdlp_bridge.resolve(url)` in-process. yt-dlp's self-update module is replaced
with a stub during vendoring — that is the one part of yt-dlp that genuinely
would violate iOS's rules, and it cannot work from a read-only bundle anyway.

**yt-dlp bridge** (`Services/RemoteResolver.swift`) hands the link to a copy of
yt-dlp running elsewhere. Worth having when you'd rather update with `pip` than
rebuild.

**Built-in extractor** (`Services/InnerTube/`) asks YouTube's own playback API
directly, in hand-written Swift. No setup and no size cost, but YouTube-only
and the first thing to break when YouTube changes. It stays last as the
fallback that always works.

All three produce the same `ResolvedMedia`, and the download and merge pipeline
is identical either way. Note that yt-dlp is used only for *extraction* here —
the transfer happens through the app's own background downloader, and merging
happens in AVFoundation, because there is no ffmpeg subprocess to call.

## What it does

- Paste a `youtube.com`, `youtu.be`, Shorts, or embed link — or a bare video ID
- Preview the video and pick a quality before committing to the download
- Downloads continue in the background and survive the app being killed
- Anything above 720p is stored by YouTube as separate video and audio files;
  both are fetched and **merged on the device with AVFoundation** — a
  passthrough remux at copy speed, which is the job ffmpeg does on desktop
- Audio-only downloads (M4A) for podcasts and music
- Offline library with local playback, search, rename, share, and delete
- Files are visible in the Files app under "YTDLP Hub", so you can move them out
- Optional copy into the system Photos library

## Building it

You need Xcode 16 or later and an Apple Developer account (a free one is enough
to run it on your own device).

1. **Vendor the Python runtime first** — the project links against it:

   ```bash
   ./Scripts/fetch-python.sh
   ```

   This downloads a CPython build for iOS, installs yt-dlp and certifi into
   `YTDLPHub/Resources/python-packages`, and trims what iOS can't use. Run
   `./Scripts/fetch-python.sh --check` any time to see what's in place. Nothing
   it produces is committed.

2. `open YTDLPHub.xcodeproj`
3. Select the **YTDLPHub** target → **Signing & Capabilities**
4. Set your **Team**, and change the bundle identifier from
   `com.example.ytdlphub` to something in your own namespace
5. Pick your iPhone as the run destination and press ⌘R

If you skip step 1, remove `Python.xcframework` from the target's Frameworks
and Embed Frameworks phases and the app still builds — it just falls back to
the built-in extractor, and Settings will say the bundled yt-dlp isn't
included.

To update yt-dlp later, re-run `./Scripts/fetch-python.sh` and rebuild.

The Simulator works for everything except Photos export.

## Running the yt-dlp bridge (optional)

On any machine that stays on and shares a network with the phone:

```bash
pip install yt-dlp
export YTDLP_HUB_TOKEN=$(openssl rand -hex 16)   # optional but recommended
python3 Server/ytdlp_hub_server.py --port 8420
```

Then in the app: **Settings → yt-dlp bridge**, turn it on, enter
`http://<that-machine>:8420` and the token, and tap **Test connection**. Turn on
**Prefer the server over on-device** if it's always reachable — yt-dlp keeps up
with YouTube's changes far faster than any bundled extractor can.

The server does extraction only; it never downloads or stores media. It speaks
plain HTTP with no rate limiting, so run it on a network you trust or put it
behind a reverse proxy.

## How the code is laid out

```
YTDLPHub/
  Models/          Value types: streams, plans, jobs, library entries
  Services/
    EmbeddedPython/
      YTDLPBridge.h/.m          CPython host; calls yt-dlp in-process
      EmbeddedYTDLPResolver.swift
    InnerTube/                  Hand-written YouTube extractor
      InnerTubeClient.swift     YouTube client identities to impersonate
      InnerTubeResolver.swift   Player API calls, format parsing
      PlayerScript.swift        JavaScriptCore host for URL unscrambling
      PlayerScriptParser.swift  Pulls functions out of YouTube's base.js
    RemoteResolver.swift        yt-dlp server bridge
    YTDLPInfo.swift             Wire format shared by both yt-dlp resolvers
    StreamSelector.swift        "1080p" -> which files to fetch
    BackgroundDownloader.swift  URLSession background transfers
    MediaMerger.swift           AVFoundation remux of video + audio
    DownloadCoordinator.swift   Queue, state machine, crash recovery
  Views/                        SwiftUI screens
  Resources/                    Vendored Python runtime lands here
Scripts/
  fetch-python.sh               Vendors CPython + yt-dlp into the app
  ytdlp_bridge.py               Python side of the in-process bridge
Server/
  ytdlp_hub_server.py           Companion extraction server
```

Design notes worth knowing before you change things:

**Nothing is stored as an absolute path.** iOS moves the app container between
installs, so `LibraryItem` records a path relative to `Paths.library` and
resolves it at read time.

**Download tasks outlive the process.** A background `URLSession` task can
finish while the app is dead, so no state lives in memory: each task carries
what it needs in `taskDescription`, jobs are persisted to `jobs.json`, and
`DownloadCoordinator.recoverInterruptedJobs()` reconciles on launch.

**The Python bridge never raises across the C boundary.** Exceptions lose their
message there, so `ytdlp_bridge.py` returns JSON with an `error` key instead
and `YTDLPInfo.classify` turns yt-dlp's prose back into a typed error.

**Every call into CPython is serialised and takes the GIL.** One extraction
runs at a time, on its own thread, which is all the app needs.

## Limitations

- **Live streams** can't be saved as a file until the broadcast ends.
- **Age-restricted, private, and members-only videos** need a signed-in
  account. Neither on-device resolver signs in. Use the yt-dlp bridge with
  `--cookies-from-browser` if you have legitimate access.
- **Playlists** resolve to their first video. Queueing a whole playlist isn't
  implemented.
- **VP9/AV1 and Opus** renditions are listed but not selected for merging —
  AVFoundation only remuxes MPEG-4 tracks, so the app sticks to H.264 + AAC.
  In practice this costs a little file size, not resolution.
- **The built-in extractor will break, periodically.** YouTube reshapes its
  player regularly. `InnerTubeClient.swift` holds the client version strings
  that go stale first; yt-dlp's `_extractor/youtube/_base.py` is where to read
  the current values. This is why it sits last in the chain rather than first.
- **`fetch-python.sh` is version-sensitive.** The Python-Apple-support release
  layout has changed between Python versions. The script searches for the
  pieces rather than assuming paths, but if a future release moves them again,
  set `PYTHON_SUPPORT_URL` to the tarball you want.

## Before you ship this

Downloading YouTube videos is against YouTube's Terms of Service unless the
video offers a download button or you own the content. Separately, Apple
rejects App Store submissions whose purpose is downloading from streaming
services (App Review Guideline 5.2.3), and Google routinely files takedowns
against apps that do it.

None of that affects building this and running it on your own device with your
own developer account, which is what a developer-program membership is for. It
does mean this is not a viable App Store product, and you should know that
before investing in it as one.
