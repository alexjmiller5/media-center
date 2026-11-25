"""Country/offer separation and conservative publication of provider responses."""

import httpx
import pytest

from core import availability


def payload():
    return {
        "id": 123,
        "results": {
            "US": {
                "link": "https://www.themoviedb.org/movie/123/watch?locale=US",
                "flatrate": [
                    {
                        "provider_id": 8,
                        "provider_name": "Provider One",
                        "logo_path": "/logo.png",
                        "display_priority": 2,
                    }
                ],
                "rent": [
                    {
                        "provider_id": 8,
                        "provider_name": "Provider One",
                        "logo_path": "/logo.png",
                        "display_priority": 1,
                    }
                ],
                "ads": [{"provider_id": 99, "provider_name": "Ads", "display_priority": 0}],
            },
            "GB": {"link": "https://www.themoviedb.org/movie/123/watch?locale=GB", "buy": []},
        },
    }


def test_country_and_offer_types_are_distinct():
    result = availability.parse(payload(), "US")
    assert result["result"] == "Ready"
    assert result["offers"] == [
        {"provider_id": "8", "offer_type": "Rent", "display_priority": 1},
        {"provider_id": "8", "offer_type": "Subscription", "display_priority": 2},
    ]
    assert result["providers"] == [{"id": "8", "name": "Provider One", "logo_path": "/logo.png"}]
    assert availability.parse(payload(), "GB")["offers"] == []
    assert availability.parse(payload(), "CA")["result"] == "Region Missing"


@pytest.mark.parametrize(
    "mutate",
    [
        lambda p: p.update(results=[]),
        lambda p: p["results"]["US"].update(flatrate={}),
        lambda p: p["results"]["US"]["rent"][0].update(provider_id=True),
        lambda p: p["results"]["US"]["rent"][0].update(display_priority=-1),
        lambda p: p["results"]["US"].update(link="https://evil.example/watch"),
        lambda p: p["results"]["US"]["rent"][0].update(provider_name=""),
    ],
)
def test_malformed_response_is_never_a_success_or_no_match(mutate):
    data = payload()
    mutate(data)
    with pytest.raises(availability.InvalidResponse):
        availability.parse(data, "US")


def test_network_errors_never_become_empty_availability():
    client = httpx.Client(transport=httpx.MockTransport(lambda r: httpx.Response(503)))
    with pytest.raises(availability.Unavailable, match="503"):
        availability.fetch(client, "movie", "123", "dummy", "US")


def test_fetch_uses_correct_kind_and_validates_identity():
    def response(request):
        assert request.url.path == "/3/tv/123/watch/providers"
        return httpx.Response(200, json=payload())

    client = httpx.Client(transport=httpx.MockTransport(response))
    assert availability.fetch(client, "tv", "123", "dummy", "US")["result"] == "Ready"
    for kind, identifier in [("other", "123"), ("movie", "../123"), ("movie", True)]:
        with pytest.raises(ValueError):
            availability.fetch(client, kind, identifier, "dummy", "US")


def test_conflicting_duplicates_cannot_hide_an_incomplete_offer_set():
    data = payload()
    data["results"]["US"]["rent"].append(
        {**data["results"]["US"]["rent"][0], "display_priority": 5}
    )
    with pytest.raises(availability.InvalidResponse):
        availability.parse(data, "US")


def test_malformed_region_fails_before_provider_request():
    def forbidden(request):
        pytest.fail("Invalid country must not cause a provider request")

    client = httpx.Client(transport=httpx.MockTransport(forbidden))
    with pytest.raises(ValueError):
        availability.fetch(client, "movie", "123", "dummy", "../US")
