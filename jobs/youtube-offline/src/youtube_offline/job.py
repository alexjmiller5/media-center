"""One reconciliation pass: every requested video that is not ready gets
downloaded (yt-dlp), uploaded as content-addressed parts, and its row patched.

The rows are the truth; subscription events only say when to look. Local state
is the per-video retry budget, persisted before each attempt.
"""

import hashlib
import json
import os
import re
import shutil
import subprocess
import time
from datetime import UTC, datetime
from pathlib import Path

import structlog

from .config import Settings
from .hub import Hub, HubError, RevisionConflict

log = structlog.get_logger()

TABLE = "youtube_videos"
PREFIX = "youtube/"
VIDEO_ID = re.compile(r"[A-Za-z0-9_-]{11}")
WORK = ["id", "deleted_at", "offline_status", "offline_file", "offline_error"]
# Gaps after failed attempts 1-4; the fifth failure gives up until re-requested.
RETRY_DELAYS = [5 * 60, 30 * 60, 2 * 3600, 12 * 3600]


class DownloadError(Exception):
    pass


class UploadError(Exception):
    pass


class Attempts:
    """Per-video retry budget: {id: {attempts, next_at}} in attempts.json."""

    def __init__(self, path: Path, data: dict):
        self.path, self.data = path, data

    @classmethod
    def load(cls, state_dir: Path) -> "Attempts":
        path = state_dir / "attempts.json"
        try:
            return cls(path, json.loads(path.read_text()))
        except (OSError, ValueError):
            return cls(path, {})

    def save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.path.with_suffix(f".{os.getpid()}.tmp")
        temporary.write_text(json.dumps(self.data))
        temporary.replace(self.path)

    def blocked(self, video_id: str, now: float) -> bool:
        entry = self.data.get(video_id)
        return entry is not None and (entry["next_at"] is None or now < entry["next_at"])

    def begin(self, video_id: str, now: float) -> dict:
        attempts = self.data.get(video_id, {"attempts": 0})["attempts"] + 1
        delay = RETRY_DELAYS[attempts - 1] if attempts <= len(RETRY_DELAYS) else None
        self.data[video_id] = {
            "attempts": attempts,
            "next_at": None if delay is None else now + delay,
        }
        self.save()  # before the attempt: a crash must not reset the budget
        return self.data[video_id]

    def reset(self, video_id: str) -> None:
        self.data.pop(video_id, None)

    def due(self, now: float) -> bool:
        return any(e["next_at"] is not None and e["next_at"] <= now for e in self.data.values())


def download(settings: Settings, video_id: str) -> Path:
    if not VIDEO_ID.fullmatch(video_id):
        raise DownloadError("not a YouTube video id")
    spool = settings.state_dir / "spool" / video_id
    spool.mkdir(parents=True, exist_ok=True)
    try:
        result = subprocess.run(
            [
                settings.yt_dlp,
                "--no-playlist",
                "--no-progress",
                "--no-simulate",
                "--format",
                settings.format,
                "--merge-output-format",
                "mp4",
                "--remux-video",
                "mp4",
                "-o",
                str(spool / "%(id)s.%(ext)s"),
                "--print",
                "after_move:filepath",
                f"https://www.youtube.com/watch?v={video_id}",
            ],
            capture_output=True,
            text=True,
            timeout=3 * 3600,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise DownloadError(f"yt-dlp did not finish: {type(error).__name__}") from None
    if result.returncode != 0:
        errors = [line for line in result.stderr.splitlines() if line.startswith("ERROR")]
        raise DownloadError((errors or result.stderr.splitlines() or ["yt-dlp failed"])[-1][:300])
    lines = result.stdout.strip().splitlines()
    path = Path(lines[-1]) if lines else None
    if path is None or not path.is_file() or path.parent != spool:
        raise DownloadError("yt-dlp reported no downloaded file")
    return path


def upload(hub: Hub, video_id: str, path: Path, part_bytes: int) -> list[dict]:
    """Content-addressed immutable parts: a retry after a crash re-sends
    identical keys, and an existing key is accepted only if HEAD proves the
    same bytes."""
    single = path.stat().st_size <= part_bytes
    mime = "video/mp4" if single else "application/octet-stream"
    parts = []
    with path.open("rb") as source:
        while chunk := source.read(part_bytes):
            digest = hashlib.sha256(chunk).hexdigest()
            key = f"{PREFIX}{video_id}/{digest}"
            response = hub.put_file(key, chunk, digest, mime)
            if response.status_code == 412:
                response = hub.head_file(key)
                same = response.status_code == 200 and (
                    response.headers.get("X-Content-SHA256") == digest
                    and response.headers.get("Content-Length") == str(len(chunk))
                )
                if not same:
                    raise UploadError(f"{key} exists with different content")
            elif response.status_code != 201 or response.json().get("sha256") != digest:
                raise UploadError(f"upload rejected: HTTP {response.status_code}")
            parts.append({"key": key, "bytes": len(chunk), "sha256": digest})
    return parts


def patch(hub: Hub, video_id: str, values: dict) -> bool:
    """Revision-checked patch against the row's CURRENT revision (downloads are
    long; the user may have edited the row meanwhile)."""
    for _ in range(3):
        rows = hub.rows(TABLE, ["id", "updated_at", "hub_at", "deleted_at"], {"id": video_id})
        if not rows or rows[0]["deleted_at"]:
            return False
        revision = {"updated_at": rows[0]["updated_at"], "hub_at": rows[0]["hub_at"]}
        try:
            hub.patch(TABLE, video_id, values, revision)
            return True
        except RevisionConflict:
            continue
    raise HubError(f"patch of {video_id} kept conflicting")


def _gb(n: int) -> str:
    return f"{n / 1e9:.2f} GB"


def reconcile(hub: Hub, settings: Settings, attempts: Attempts, *, fetch=download, now=time.time):
    requested = [r for r in hub.rows(TABLE, WORK, {"offline_requested": 1}) if not r["deleted_at"]]
    # Retained files are never deleted through the hub, so every ready row
    # counts toward the cap, requested or not, live or tombstoned.
    used = sum(
        r["offline_bytes"] or 0
        for r in hub.rows(TABLE, ["id", "offline_bytes"], {"offline_status": "ready"})
    )
    wanted = {r["id"] for r in requested}
    for video_id in [v for v in attempts.data if v not in wanted]:
        attempts.reset(video_id)
    attempts.save()

    for row in requested:
        video_id = row["id"]
        if row["offline_status"] == "ready" and row["offline_file"]:
            attempts.reset(video_id)
            continue
        if attempts.blocked(video_id, now()):
            continue
        if used >= settings.storage_cap_bytes:
            _refuse(hub, row, used, settings.storage_cap_bytes)
            continue
        entry = attempts.begin(video_id, now())
        patch(hub, video_id, {"offline_status": "downloading", "offline_error": None})
        log.info("downloading", video=video_id, attempt=entry["attempts"])
        try:
            path = fetch(settings, video_id)
            size = path.stat().st_size
            if used + size > settings.storage_cap_bytes:
                attempts.reset(video_id)
                _refuse(hub, {**row, "offline_status": None}, used, settings.storage_cap_bytes)
            else:
                parts = upload(hub, video_id, path, settings.part_bytes)
                patch(
                    hub,
                    video_id,
                    {
                        "offline_status": "ready",
                        "offline_file": json.dumps(parts),
                        "offline_bytes": size,
                        "offline_error": None,
                    },
                )
                used += size
                attempts.reset(video_id)
                log.info("ready", video=video_id, bytes=size, parts=len(parts))
            shutil.rmtree(settings.state_dir / "spool" / video_id, ignore_errors=True)
        except (DownloadError, UploadError) as error:
            retry = entry["next_at"]
            when = (
                f"retrying after {datetime.fromtimestamp(retry, UTC):%Y-%m-%d %H:%M} UTC"
                if retry is not None
                else "gave up; turn offline off and on to retry"
            )
            message = f"{error} (attempt {entry['attempts']}); {when}"
            patch(hub, video_id, {"offline_status": "failed", "offline_error": message[:500]})
            log.warning("failed", video=video_id, attempt=entry["attempts"], error=str(error))
        attempts.save()


def _refuse(hub: Hub, row: dict, used: int, cap: int) -> None:
    message = (
        f"Offline storage cap reached: {_gb(used)} of {_gb(cap)} used by retained videos. "
        "Raise the cap to continue; retained files are not deleted automatically."
    )
    if row["offline_status"] == "storage_full" and row["offline_error"] == message:
        return
    patch(hub, row["id"], {"offline_status": "storage_full", "offline_error": message})
    log.warning("storage cap", video=row["id"], used=used, cap=cap)
