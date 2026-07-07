from datetime import UTC, datetime
from pathlib import Path

from core import pipeline
from core.watcher import Source

FIXTURES = Path(__file__).parent / "fixtures"


def test_poll_all_sources_writes_new_entries_and_advances_cursor(mocker):
    source = Source(
        page_id="p1",
        name="Example Blog",
        feed_url="https://blog.example.com/rss",
        data_source_id=pipeline.SOURCE_DBS[0],
        # cursor between the 2nd and 3rd fixture posts -> exactly 1 new entry
        last_checked=datetime(2026, 7, 3, tzinfo=UTC),
    )
    notion = mocker.Mock()
    notion.list_sources.side_effect = lambda db: [source] if db == pipeline.SOURCE_DBS[0] else []
    notion.upsert_entry.return_value = True

    http = mocker.Mock()
    http.get.return_value = mocker.Mock(text=(FIXTURES / "rss2.xml").read_text())

    result = pipeline.poll_all_sources(notion=notion, http=http)

    assert result == {"ok": True, "sources_checked": 1, "entries_created": 1}
    (target, entry), _ = notion.upsert_entry.call_args
    assert target == pipeline.SOURCE_DBS[0]  # routed back to the DB the source came from
    assert entry.url == "https://blog.example.com/third"
    notion.mark_checked.assert_called_once()
    assert notion.mark_checked.call_args.args[0] == "p1"


def test_poll_all_sources_survives_a_broken_feed(mocker):
    bad = Source(
        page_id="p-bad",
        name="Broken",
        feed_url="https://down.example/feed",
        data_source_id=pipeline.SOURCE_DBS[0],
        last_checked=None,
    )
    notion = mocker.Mock()
    notion.list_sources.side_effect = lambda db: [bad] if db == pipeline.SOURCE_DBS[0] else []

    http = mocker.Mock()
    http.get.side_effect = RuntimeError("connection refused")

    result = pipeline.poll_all_sources(notion=notion, http=http)

    assert result["ok"] is True
    assert result["sources_checked"] == 0
    notion.mark_checked.assert_not_called()  # cursor NOT advanced on failure


def test_run_triggers_poll(mocker):
    poll = mocker.patch.object(pipeline, "poll_all_sources", return_value={"ok": True})
    assert pipeline.run({"trigger": "cron"}) == {"ok": True}
    poll.assert_called_once()
