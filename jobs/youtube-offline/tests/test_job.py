import hashlib
import json
import shutil
from pathlib import Path

import httpx
import pytest

from fakehub import SUB, URL, FakeHub
from youtube_offline.config import CredentialError, Settings, resolve_token
from youtube_offline.hub import Hub
from youtube_offline.job import (
    RETRY_DELAYS,
    Attempts,
    DownloadError,
    download,
    reconcile,
)
from youtube_offline.main import watch

CLIP = Path(__file__).parent / "fixtures" / "clip.mp4"
FAKE_YT_DLP = Path(__file__).parent / "fake-yt-dlp"
VIDEO = "dQw4w9WgXcQ"
OTHER = "-abcdefghij"


@pytest.fixture
def settings(tmp_path):
    return Settings(
        hub_url=URL,
        subscription_id=SUB,
        hub_token="fixture-token",
        state_dir=tmp_path / "state",
        storage_cap_bytes=10**9,
    )


def hub_for(fake) -> Hub:
    return Hub(URL, lambda: "fixture-token", httpx.Client(transport=httpx.MockTransport(fake)))


class Clock:
    def __init__(self):
        self.t = 1_000_000.0

    def __call__(self):
        return self.t


def downloader(source=CLIP, calls=None):
    def fetch(settings, video_id):
        if calls is not None:
            calls.append(video_id)
        out = settings.state_dir / "spool" / video_id / f"{video_id}.mp4"
        out.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, out)
        return out

    return fetch


def failing(message="ERROR: Video unavailable"):
    def fetch(settings, video_id):
        raise DownloadError(message)

    return fetch


def stored(fake, row) -> bytes:
    """What a client reassembles from the row's offline_file parts, verified."""
    data = b""
    for part in json.loads(row["offline_file"]):
        blob, _mime = fake.files[part["key"]]
        assert hashlib.sha256(blob).hexdigest() == part["sha256"] and len(blob) == part["bytes"]
        data += blob
    return data


def run(fake, settings, fetch, clock=None):
    attempts = Attempts.load(settings.state_dir)
    reconcile(hub_for(fake), settings, attempts, fetch=fetch, now=clock or Clock())
    return attempts


def test_requested_video_is_downloaded_uploaded_and_marked_ready(settings):
    fake = FakeHub([{"id": VIDEO, "offline_requested": 1}, {"id": OTHER}])
    run(fake, settings, downloader())
    row = fake.rows[VIDEO]
    assert row["offline_status"] == "ready" and row["offline_error"] is None
    assert stored(fake, row) == CLIP.read_bytes()
    assert row["offline_bytes"] == CLIP.stat().st_size
    [part] = json.loads(row["offline_file"])
    assert part["key"] == f"youtube/{VIDEO}/{part['sha256']}"
    assert fake.files[part["key"]][1] == "video/mp4"
    assert [p["offline_status"] for p in fake.patches] == ["downloading", "ready"]
    assert fake.rows[OTHER]["offline_status"] is None
    assert not (settings.state_dir / "spool" / VIDEO).exists()


def test_large_video_is_split_into_parts_each_within_the_upload_limit(settings, tmp_path):
    big = tmp_path / "big.mp4"
    big.write_bytes(bytes(range(256)) * 100_000)  # 25.6 MB
    settings = settings.model_copy(update={"part_bytes": 10 * 1024 * 1024})
    fake = FakeHub([{"id": VIDEO, "offline_requested": 1}], max_body=settings.part_bytes)
    run(fake, settings, downloader(big))
    row = fake.rows[VIDEO]
    parts = json.loads(row["offline_file"])
    assert len(parts) == 3 and stored(fake, row) == big.read_bytes()
    assert {fake.files[p["key"]][1] for p in parts} == {"application/octet-stream"}
    assert row["offline_bytes"] == big.stat().st_size


def test_ready_and_unrequested_rows_are_left_alone(settings):
    fake = FakeHub(
        [
            {"id": VIDEO, "offline_requested": 1, "offline_status": "ready", "offline_file": "[]"},
            {"id": OTHER, "offline_requested": 0},
        ]
    )
    calls = []
    run(fake, settings, downloader(calls=calls))
    assert calls == [] and fake.patches == []


def test_failure_is_visible_and_retried_with_backoff_then_gives_up(settings):
    fake, clock = FakeHub([{"id": VIDEO, "offline_requested": 1}]), Clock()
    attempts = Attempts.load(settings.state_dir)
    hub = hub_for(fake)
    for n, delay in enumerate(RETRY_DELAYS, start=1):
        reconcile(hub, settings, attempts, fetch=failing(), now=clock)
        row = fake.rows[VIDEO]
        assert row["offline_status"] == "failed"
        assert (
            "Video unavailable" in row["offline_error"] and f"attempt {n}" in row["offline_error"]
        )
        assert "retrying after" in row["offline_error"]
        patches = len(fake.patches)
        reconcile(hub, settings, attempts, fetch=failing(), now=clock)  # not due yet
        assert len(fake.patches) == patches and not attempts.due(clock())
        clock.t += delay
        assert attempts.due(clock())
    reconcile(hub, settings, attempts, fetch=failing(), now=clock)
    assert "gave up" in fake.rows[VIDEO]["offline_error"]
    clock.t += 10**9
    assert not attempts.due(clock())
    # Turning the request off and on resets the budget.
    attempts.reset(VIDEO)
    reconcile(hub, settings, attempts, fetch=downloader(), now=clock)
    assert fake.rows[VIDEO]["offline_status"] == "ready"


def test_attempt_is_persisted_before_the_download_starts(settings):
    fake = FakeHub([{"id": VIDEO, "offline_requested": 1}])

    def crash(settings, video_id):
        assert Attempts.load(settings.state_dir).data[VIDEO]["attempts"] == 1
        raise KeyboardInterrupt

    with pytest.raises(KeyboardInterrupt):
        run(fake, settings, crash)
    assert Attempts.load(settings.state_dir).blocked(VIDEO, Clock()())


def test_storage_cap_refuses_new_downloads_visibly(settings):
    cap = CLIP.stat().st_size * 2
    settings = settings.model_copy(update={"storage_cap_bytes": cap})
    fake = FakeHub(
        [
            {"id": OTHER, "offline_status": "ready", "offline_bytes": cap, "offline_file": "[]"},
            {"id": VIDEO, "offline_requested": 1},
        ]
    )
    calls = []
    run(fake, settings, downloader(calls=calls))
    assert calls == []
    assert fake.rows[VIDEO]["offline_status"] == "storage_full"
    assert "cap" in fake.rows[VIDEO]["offline_error"]
    run(fake, settings, downloader(calls=calls))
    assert len(fake.patches) == 1  # an unchanged refusal is not rewritten


def test_download_that_would_exceed_the_cap_is_not_uploaded(settings):
    settings = settings.model_copy(update={"storage_cap_bytes": CLIP.stat().st_size - 1})
    fake = FakeHub([{"id": VIDEO, "offline_requested": 1}])
    run(fake, settings, downloader())
    assert fake.files == {} and fake.rows[VIDEO]["offline_status"] == "storage_full"


def test_revision_conflict_rereads_the_row_and_retries(settings):
    fake = FakeHub([{"id": VIDEO, "offline_requested": 1}])
    fake.fail_patch_conflicts = 2
    run(fake, settings, downloader())
    assert fake.rows[VIDEO]["offline_status"] == "ready"
    assert fake.rows[VIDEO]["note"] == "concurrent edit"


def test_identical_existing_part_is_verified_and_reused(settings):
    fake = FakeHub([{"id": VIDEO, "offline_requested": 1}])
    digest = hashlib.sha256(CLIP.read_bytes()).hexdigest()
    fake.files[f"youtube/{VIDEO}/{digest}"] = (CLIP.read_bytes(), "video/mp4")
    run(fake, settings, downloader())
    assert fake.rows[VIDEO]["offline_status"] == "ready"


def test_existing_key_with_different_bytes_is_never_trusted(settings):
    fake = FakeHub([{"id": VIDEO, "offline_requested": 1}])
    digest = hashlib.sha256(CLIP.read_bytes()).hexdigest()
    fake.files[f"youtube/{VIDEO}/{digest}"] = (b"corrupt", "video/mp4")
    run(fake, settings, downloader())
    assert fake.rows[VIDEO]["offline_status"] == "failed"
    assert "different content" in fake.rows[VIDEO]["offline_error"]


def test_rejected_upload_marks_the_row_failed(settings):
    fake = FakeHub([{"id": VIDEO, "offline_requested": 1}], max_body=10)
    run(fake, settings, downloader())
    assert fake.rows[VIDEO]["offline_status"] == "failed"
    assert "413" in fake.rows[VIDEO]["offline_error"]


def test_download_runs_yt_dlp_with_the_configured_format(settings, monkeypatch):
    settings = settings.model_copy(update={"yt_dlp": str(FAKE_YT_DLP), "format": "fixture-fmt"})
    monkeypatch.setenv("FAKE_YTDLP_SOURCE", str(CLIP))
    log = settings.state_dir / "argv"
    monkeypatch.setenv("FAKE_YTDLP_ARGV", str(log))
    path = download(settings, OTHER)
    assert path.read_bytes() == CLIP.read_bytes() and path.name == f"{OTHER}.mp4"
    argv = log.read_text().split("\n")
    assert "fixture-fmt" in argv and f"https://www.youtube.com/watch?v={OTHER}" in argv
    assert "--merge-output-format" in argv


def test_default_format_prefers_h264_within_720p():
    from youtube_offline.config import DEFAULT_FORMAT

    first = DEFAULT_FORMAT.split("/")[0]
    assert "vcodec^=avc1" in first and "height<=720" in first
    assert all("height<=720" in choice for choice in DEFAULT_FORMAT.split("/"))


def test_download_failure_carries_the_yt_dlp_error(settings, monkeypatch):
    settings = settings.model_copy(update={"yt_dlp": str(FAKE_YT_DLP)})
    monkeypatch.setenv("FAKE_YTDLP_FAIL", "1")
    with pytest.raises(DownloadError, match="Video unavailable"):
        download(settings, VIDEO)


@pytest.mark.parametrize("video_id", ["short", "dQw4w9WgXcQ/..", "../../etc/pw"])
def test_non_youtube_ids_are_refused(settings, video_id):
    with pytest.raises(DownloadError):
        download(settings, video_id)


def test_watch_reconciles_at_start_then_acks_each_batch_after_processing(settings):
    fake = FakeHub([{"id": VIDEO}, {"id": OTHER, "offline_requested": 1}])
    fake.on_poll = lambda: fake.request_offline(VIDEO)  # requested while watching
    seen = []

    def fetch(s, video_id):
        assert fake.acks == []  # processed before the ACK
        seen.append(video_id)
        return downloader()(s, video_id)

    watch(hub_for(fake), settings, Attempts.load(settings.state_dir), fetch=fetch, iterations=2)
    assert seen == [OTHER, VIDEO] and fake.acks == ["d1"]
    assert {r["offline_status"] for r in fake.rows.values()} == {"ready"}


def test_watch_backs_off_when_the_hub_is_unavailable_and_reconciles_again(settings):
    fake, sleeps, calls = FakeHub([{"id": VIDEO, "offline_requested": 1}]), [], []
    fake.status = 503

    def sleep(delay):
        sleeps.append(delay)
        fake.status = None  # the hub comes back

    attempts = Attempts.load(settings.state_dir)
    watch(
        hub_for(fake), settings, attempts, fetch=downloader(calls=calls), sleep=sleep, iterations=2
    )
    assert sleeps == [1.0] and calls == [VIDEO]


def test_credential_seam(settings):
    assert resolve_token(settings) == "fixture-token"
    cmd = settings.model_copy(update={"hub_token": None, "token_command": ["printf", "%s", "t k"]})
    assert resolve_token(cmd) == "t k"
    with pytest.raises(CredentialError):
        resolve_token(settings.model_copy(update={"hub_token": None, "token_command": ["false"]}))
