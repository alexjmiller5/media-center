from datetime import UTC, datetime

from core.notion import NotionClient
from core.watcher import Entry


def resp(mocker, payload):
    r = mocker.Mock()
    r.json.return_value = payload
    r.raise_for_status.return_value = None
    return r


def make_client(mocker):
    http = mocker.Mock()
    return NotionClient("secret-key", http=http), http


def source_page(page_id, name, feed_url, status="Tracked", last_checked=None):
    return {
        "id": page_id,
        "properties": {
            "Name": {"type": "title", "title": [{"plain_text": name}]},
            "Feed URL": {"type": "url", "url": feed_url},
            "Site URL": {"type": "url", "url": "https://site.example"},
            "Status": {"type": "select", "select": {"name": status} if status else None},
            "Last Checked": {
                "type": "date",
                "date": {"start": last_checked} if last_checked else None,
            },
            "Notes": {"type": "rich_text", "rich_text": []},
        },
    }


def test_list_sources_keeps_only_tracked_with_feed(mocker):
    client, http = make_client(mocker)
    http.post.return_value = resp(
        mocker,
        {
            "results": [
                source_page("p1", "Cherri", "https://x/releases.atom", last_checked="2026-07-01"),
                source_page("p2", "Paused", "https://x/feed", status="Paused"),
                source_page("p3", "No feed", None),
            ],
            "has_more": False,
        },
    )

    sources = client.list_sources("db-1")

    http.post.assert_called_once_with("/data_sources/db-1/query", json={})
    assert [s.page_id for s in sources] == ["p1"]
    assert sources[0].name == "Cherri"
    assert sources[0].data_source_id == "db-1"
    assert sources[0].last_checked == datetime(2026, 7, 1, tzinfo=UTC)


def test_upsert_creates_when_url_not_present(mocker):
    client, http = make_client(mocker)
    http.post.side_effect = [
        resp(mocker, {"results": []}),  # existence query
        resp(mocker, {"id": "new-page"}),  # create
    ]
    entry = Entry(
        guid="g1",
        title="v2.4.1",
        url="https://x/releases/v2.4.1",
        published=datetime(2026, 6, 20, tzinfo=UTC),
    )

    assert client.upsert_entry("db-1", entry) is True

    create_call = http.post.call_args_list[1]
    assert create_call.args[0] == "/pages"
    body = create_call.kwargs["json"]
    assert body["parent"] == {"type": "data_source_id", "data_source_id": "db-1"}
    assert body["properties"]["Name"]["title"][0]["text"]["content"] == "v2.4.1"
    assert body["properties"]["Site URL"]["url"] == "https://x/releases/v2.4.1"


def test_upsert_skips_when_url_already_exists(mocker):
    client, http = make_client(mocker)
    http.post.return_value = resp(mocker, {"results": [{"id": "existing"}]})
    entry = Entry(guid="g1", title="dup", url="https://x/dup", published=None)

    assert client.upsert_entry("db-1", entry) is False
    assert http.post.call_count == 1  # query only, no create


def test_mark_checked_patches_last_checked(mocker):
    client, http = make_client(mocker)
    http.patch.return_value = resp(mocker, {"id": "p1"})
    when = datetime(2026, 7, 7, 4, 30, tzinfo=UTC)

    client.mark_checked("p1", when)

    http.patch.assert_called_once_with(
        "/pages/p1",
        json={"properties": {"Last Checked": {"date": {"start": when.isoformat()}}}},
    )
