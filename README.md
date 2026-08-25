# YTDLP Hub

A native iOS app for saving YouTube videos to your device. Paste a link, pick a
quality, and the video downloads into the app's library where it plays offline.

Built with SwiftUI, targeting iOS 17 and later, iPhone and iPad.

## The yt-dlp problem, and what this does instead

yt-dlp is a command line program. iOS does not let an app spawn subprocesses or
execute downloaded code, so **yt-dlp cannot run inside an iOS app** — not
bundled, not compiled in, not via a Python runtime. Any App Store app that
claims to "use yt-dlp" is either talking to a server, or doing the extraction
itself in native code.

This app does both, and you choose which:

| | On-device extractor | yt-dlp bridge |
|---|---|---|
| Where extraction happens | On the iPhone | On a machine you run |
| Setup | None | Run one Python script |
| Sites | YouTube only | Everything yt-dlp supports |
| Keeping up with YouTube | Needs an app update | `pip install -U yt-dlp` |

The **on-device extractor** (`Services/InnerTube/`) asks YouTube's own playback
API — the endpoint the official YouTube apps use — for the list of media files
behind a video, then downloads them directly. Nothing leaves the device except
the request to YouTube itself.

The **yt-dlp bridge** (`Services/RemoteResolver.swift`) hands the link to a
copy of yt-dlp running somewhere that can execute it — a Mac, a Raspberry Pi, a
home server — and gets back the same direct media URLs. Extraction happens
there; the download still happens on the phone. `Server/ytdlp_hub_server.py` is
the companion script, and it's about 150 lines.

Downloading happens the same way in both cases, and neither one proxies your
video through anything.

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

1. `open YTDLPHub.xcodeproj`
2. Select the **YTDLPHub** target → **Signing & Capabilities**
3. Set your **Team**, and change the bundle identifier from
   `com.example.ytdlphub` to something in your own namespace
4. Pick your iPhone as the run destination and press ⌘R

There are no package dependencies and nothing to install first.

The Simulator works for everything except Photos export. Downloads are real in
the Simulator, so it's a fine place to test.

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
    InnerTube/     On-device extraction
      InnerTubeClient.swift     YouTube client identities to impersonate
      InnerTubeResolver.swift   Player API calls, format parsing
      PlayerScript.swift        JavaScriptCore host for URL unscrambling
      PlayerScriptParser.swift  Pulls functions out of YouTube's base.js
    RemoteResolver.swift        yt-dlp server bridge
    StreamSelector.swift        "1080p" -> which files to fetch
    BackgroundDownloader.swift  URLSession background transfers
    MediaMerger.swift           AVFoundation remux of video + audio
    DownloadCoordinator.swift   Queue, state machine, crash recovery
  Views/           SwiftUI screens
Server/
  ytdlp_hub_server.py           Companion extraction server
```

Two design notes worth knowing before you change things:

**Nothing is stored as an absolute path.** iOS moves the app container between
installs, so `LibraryItem` records a path relative to `Paths.library` and
resolves it at read time.

**Download tasks outlive the process.** A background `URLSession` task can
finish while the app is dead, so no state lives in memory: each task carries
what it needs in `taskDescription`, jobs are persisted to `jobs.json`, and
`DownloadCoordinator.recoverInterruptedJobs()` reconciles on launch.

## Limitations

- **Live streams** can't be saved as a file until the broadcast ends.
- **Age-restricted, private, and members-only videos** need a signed-in
  account. The on-device extractor doesn't sign in. Use the yt-dlp bridge with
  `--cookies-from-browser` if you have legitimate access.
- **Playlists** resolve to their first video. Queueing a whole playlist isn't
  implemented.
- **VP9/AV1 and Opus** renditions are listed but not selected for merging —
  AVFoundation only remuxes MPEG-4 tracks, so the app sticks to H.264 + AAC.
  In practice this costs a little file size, not resolution.
- **The on-device extractor will break, periodically.** YouTube reshapes its
  player regularly. `InnerTubeClient.swift` holds the client version strings
  that go stale first; yt-dlp's `_extractor/youtube/_base.py` is the place to
  read the current values from. Every extraction failure is non-fatal — the app
  falls back through several clients and then to the bridge. This is the honest
  tradeoff of doing extraction on-device, and the reason the bridge exists.

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
