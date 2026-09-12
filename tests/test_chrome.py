import json

import httpx
import pytest

from core import feeds, pipeline
from core.watcher import Entry
from test_pipeline import FakeHub

SOURCE_URL = "https://www.google.com/chrome/whats-new/archive/"
SOURCE = {"id": SOURCE_URL, "fetch": "chrome"}


def card(feature="FeatureOne", title="Arrange your tabs"):
    return f"""
    <div class="chr-card-simple--feature-2025" data-id="card-{feature}">
      <div><img src="preview.webp"><h2>Productivity</h2><h3>{title}</h3></div>
      <button data-props-modaldispatcher='{{"id":"{feature}-modal"}}'>Learn more</button>
    </div>"""


def modal(feature="FeatureOne", body="<p>Arrange tabs in a new layout.</p>"):
    return f"""
    <dialog id="{feature}-modal">
      <button>Close</button>
      <div class="whats-new-feature-2025__text-wrapper">
        <h3>Arrange your tabs</h3>{body}<button>Try it now</button>
      </div>
      <div><video><source src="preview.webm"></video><button>Play</button></div>
    </dialog>"""


def poll(html, *, status=200, source=SOURCE):
    requests = []

    def respond(request):
        requests.append(request)
        return httpx.Response(status, text=html)

    with httpx.Client(transport=httpx.MockTransport(respond)) as http:
        result = feeds.entries(source, http)
    assert len(requests) == 1
    assert str(requests[0].url) == SOURCE_URL
    return result


def test_chrome_dispatch_uses_verified_modal_fragment_and_original_text():
    body = """<p>Move tabs to the <strong>side</strong> &amp; see more.</p>
        <ol><li>Open the tab menu.</li><li>Choose <b>Side tabs</b>.</li></ol>"""
    (entry,) = poll(card() + modal(body=body))
    identity = SOURCE_URL + "#FeatureOne-modal"
    assert (entry.guid, entry.url, entry.row_id) == ("FeatureOne", identity, identity)
    assert entry.title == "Arrange your tabs"
    assert entry.published is None
    (row,) = feeds.article_rows(SOURCE_URL, [entry])
    assert row["id"] == identity
    assert row["feed_id"] == SOURCE_URL
    assert row["published_at"] is None
    assert row["status"] == "Not Started"
    assert json.loads(row["content"]) == {
        "feature_id": "FeatureOne",
        "text": "Move tabs to the side & see more.\n\nOpen the tab menu.\n\nChoose Side tabs.",
    }


def test_duplicate_features_and_repeat_polls_keep_distinct_stable_row_ids():
    html = card() + card() + card("FeatureTwo", "Save a page") + modal() + modal("FeatureTwo")
    first = poll(html)
    # Provider titles/instructions may change without making an old feature new.
    second = poll(html.replace("Arrange your tabs", "A refreshed title"))
    assert len(first) == len(second) == 2
    first_ids = [row["id"] for row in feeds.article_rows(SOURCE_URL, first)]
    assert first_ids == [SOURCE_URL + "#FeatureOne-modal", SOURCE_URL + "#FeatureTwo-modal"]
    assert [row["id"] for row in feeds.article_rows(SOURCE_URL, second)] == first_ids


@pytest.mark.parametrize("deleted", [False, True])
def test_pipeline_repeat_polls_only_insert_new_provider_ids_and_preserve_state(deleted):
    hub = FakeHub({"feeds": [SOURCE]})
    html = card() + card() + modal()
    with httpx.Client(
        transport=httpx.MockTransport(lambda _: httpx.Response(200, text=html))
    ) as http:
        first = pipeline.sync_feeds(hub, http)
        assert first == {"feeds": 1, "articles": 1, "failed": 0, "rejected": 0}
        existing = hub.tables["articles"][0]
        existing.update(status="Finished", note="Keep this note", tags='["saved"]')
        if deleted:
            existing["deleted_at"] = "2026-01-01T00:00:00.000Z"
        saved = existing.copy()
        html = html.replace("Arrange your tabs", "Changed provider title")
        html += card("FeatureTwo", "Save a page") + modal("FeatureTwo")
        second = pipeline.sync_feeds(hub, http)
        assert second == {"feeds": 1, "articles": 1, "failed": 0, "rejected": 0}
        third = pipeline.sync_feeds(hub, http)
        assert third == {"feeds": 1, "articles": 0, "failed": 0, "rejected": 0}
    assert hub.tables["articles"][0] == saved
    assert {row["id"] for row in hub.tables["articles"]} == {
        SOURCE_URL + "#FeatureOne-modal",
        SOURCE_URL + "#FeatureTwo-modal",
    }
    assert len(hub.pushed["articles"]) == 2


@pytest.mark.parametrize("platform", ["mac", "win", "linux", "android", "ios", "ALL"])
def test_platform_wrappers_are_read_without_browser_environment(platform):
    html = f'<div data-environment="{platform},ALL,ALL">{card()}{modal()}</div>'
    assert poll(html)[0].content["text"] == "Arrange tabs in a new layout."


def test_all_platform_instructions_and_repeated_identical_markup():
    body = """<div data-environment="mac,ALL,ALL"><p>On Mac, open the menu.</p></div>
      <div data-environment="win,ALL,ALL"><p>On Windows, open the menu.</p></div>
      <div data-environment="ALL,ALL,ALL"><p>Choose a layout.</p></div>
      <p>Choose a layout.</p>"""
    # Modal/card order is irrelevant; identical duplicate DOM IDs do not duplicate entries.
    result = poll(modal(body=body) + modal(body=body) + card())
    assert len(result) == 1
    assert result[0].content["text"] == (
        "On Mac, open the menu.\n\nOn Windows, open the menu.\n\nChoose a layout."
    )


def test_original_text_excludes_active_markup_controls_and_page_chrome():
    body = """<style>secret-style</style><script>secret-script</script>
      <p>Keep <em>your</em> tabs&nbsp;together.<br/>Next line.
        <script>secret-inline</script><svg><text>secret-icon</text></svg>
        <button>secret-control</button><template><p>secret-template</p></template>
        <a href="javascript:secret-link()" onclick="secret-handler()">Read the guide</a>.</p>
      <p>Write &lt;example&gt; &amp; enjoy café.</p>"""
    html = (
        "<nav><p>secret-nav</p></nav>" + card(title="Tabs &amp; <em>more</em>") + modal(body=body)
    )
    (entry,) = poll(html)
    assert entry.title == "Tabs & more"
    assert entry.content["text"] == (
        "Keep your tabs together. Next line. Read the guide.\n\nWrite <example> & enjoy café."
    )
    (row,) = feeds.article_rows(SOURCE_URL, [entry])
    assert "secret-" not in row["content"]
    assert json.loads(row["content"]) == entry.content


@pytest.mark.parametrize(
    "html",
    [
        "",
        "<html><body>Try again later</body></html>",
        "<h3>Feature title</h3><p>Unrecognized page</p>",
        card(),
        modal(),
        card().replace("card-FeatureOne", "card-") + modal(),
        card().replace("card-FeatureOne", "card-Bad#ID") + modal(),
        card(title="  ") + modal(),
        card().replace("<h3>", "<h4>").replace("</h3>", "</h4>") + modal(),
        card().replace("data-props-modaldispatcher=", "data-other=") + modal(),
        card().replace('{"id":"FeatureOne-modal"}', "{broken}") + modal(),
        card().replace('{"id":"FeatureOne-modal"}', "[]") + modal(),
        card().replace('{"id":"FeatureOne-modal"}', '{"id":null}') + modal(),
        card().replace('"FeatureOne-modal"', '"Other-modal"') + modal(),
        card() + modal().replace('id="FeatureOne-modal"', 'id="Another-modal"'),
        card() + modal(body="<h3>Title without instructions</h3>"),
        card() + modal(body="<p>  </p>"),
        card() + modal(body="<p><script>Not feature text</script></p>"),
        card() + modal().replace("</dialog>", ""),
        card() + modal().replace("</p>", "</div>"),
        card() + modal() + card("FeatureTwo"),
        card() + modal() + '<div data-id="card-FeatureTwo"><h3>Truncated',
        card() + card(title="Conflicting title") + modal(),
        card() + modal() + modal(body="<p>Conflicting instructions</p>"),
    ],
)
def test_empty_unrecognized_or_malformed_archive_fails_before_returning_entries(html):
    with pytest.raises(ValueError, match="Chrome"):
        poll(html)


def test_complete_first_feature_then_card_missing_data_id_rejects_partial_archive():
    second = card("FeatureTwo").replace(' data-id="card-FeatureTwo"', "") + modal("FeatureTwo")
    with pytest.raises(ValueError, match="Chrome"):
        poll(card() + modal() + second)


def test_complete_first_feature_then_unfinished_opening_tag_rejects_partial_archive():
    with pytest.raises(ValueError, match="Chrome"):
        poll(card() + modal() + '<div data-id="card-FeatureTwo"')


def test_http_failure_is_not_a_healthy_empty_poll():
    with pytest.raises(httpx.HTTPStatusError):
        poll("<html>Unavailable</html>", status=503)


def test_wrong_source_is_rejected_before_fetching():
    with httpx.Client(
        transport=httpx.MockTransport(lambda _: pytest.fail("must not fetch"))
    ) as http:
        with pytest.raises(ValueError, match="Chrome"):
            feeds.entries({"id": "https://example.com/archive/", "fetch": "chrome"}, http)


def test_ordinary_entries_still_drop_tracking_fragments():
    entry = Entry("id", "Title", "https://example.com/post/?utm_source=test#tracking", None)
    (row,) = feeds.article_rows("https://example.com/feed", [entry])
    assert row["id"] == "https://example.com/post"
    assert "content" not in row
    assert feeds.canonical_url(SOURCE_URL + "#FeatureOne-modal") == SOURCE_URL.rstrip("/")
