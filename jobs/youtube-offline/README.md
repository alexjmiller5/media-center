# YouTube offline job

Keeps requested YouTube videos as checksummed offline copies in a Soma hub.
A user sets `youtube_videos.offline_requested = 1` (Iris or Media Center); this
job, running on an always-on Mac, downloads the video with yt-dlp (H.264 mp4 at
<= 720p by default), uploads it through the hub files API and writes the result
back on the row. Clients then download the copy into their own cache.

The hub never connects to the Mac. The job holds an outbound long poll on a hub
subscription (`durable-pull-v1`) and reacts within about a second.

## Row contract (`youtube_videos`)

| Column | Writer | Meaning |
|---|---|---|
| `offline_requested` | user | 1 = keep an offline copy |
| `offline_status` | job | `downloading`, `ready`, `failed` or `storage_full` |
| `offline_file` | job | JSON array of parts `[{key, bytes, sha256}]`; concatenated in order they are the mp4 |
| `offline_bytes` | job | total mp4 size |
| `offline_error` | job | why the last attempt failed or was refused, and when it retries |

Parts are content-addressed (`youtube/<video id>/<sha256>`) and immutable; a video
larger than one hub upload (`part_bytes`, default 90 MiB, under Cloudflare's
100 MB request limit) has several. Verify each part against its `sha256`.

- Failures retry after 5 min, 30 min, 2 h and 12 h, then give up; turning the
  request off and on resets the budget. Attempts are persisted before they start.
- New downloads are refused with `storage_full` once retained videos reach
  `storage_cap_bytes`. The hub cannot delete retained files, so clearing a
  request keeps the copy (and its columns) and its bytes keep counting.
- Every row is re-read before each revision-checked patch; a concurrent edit is
  retried, never overwritten.

## Install

The flake (`?dir=jobs/youtube-offline`) exports the package (yt-dlp and ffmpeg
from nixpkgs on its PATH) and `darwinModules.default`:

```nix
services.media-center.youtube-offline = {
  enable = true;
  user = "<login user>";
  hubUrl = "https://<hub>";
  subscriptionId = "<subscription id>";
  credentialCommand = [ "/usr/bin/security" "find-generic-password" "-s" "media-center.youtube-offline" "-a" "hub" "-w" ];
  storageCapBytes = 5000000000;
};
```

It runs `youtube-offline watch` as a kept-alive launchd user agent; state, the
download spool and `youtube-offline.log` live in
`~/.local/state/media-center/youtube-offline`.

## Service setup (once per hub)

1. Catalog the five columns above on `youtube_videos` (Soma catalog).
2. Create the subscription as the hub operator:
   `POST /v1/subscriptions {"label": "Media Center YouTube Offline", "sources": [{"table": "youtube_videos", "columns": ["offline_requested"]}], "start": "now"}`.
3. Give the job its own credential with exactly these grants:
   `subscriptions:consume:<id>`, `tables:read:youtube_videos`,
   `tables:read:youtube_videos:{id,updated_at,hub_at,offline_status,offline_file,offline_bytes,offline_error}`,
   `tables:patch:youtube_videos:{offline_status,offline_file,offline_bytes,offline_error}`,
   `files:read:youtube/`, `files:write:youtube/`.
4. Store it in the Mac's login Keychain from the desktop session (ssh sessions
   cannot write the Keychain), passing it to `security -i` on stdin:
   `add-generic-password -A -U -s media-center.youtube-offline -a hub -w <token>`.
   A replacement Mac gets a new credential; revoke the old one.

## Develop

`just test`, `just check`, `just fmt`; `just dev` runs the watcher and `just run`
one reconciliation pass with your `YOUTUBE_OFFLINE_*` environment. Tests drive
the job against an in-process fake hub and a fake yt-dlp; the fixture clip is a
synthetic one-second test pattern.
