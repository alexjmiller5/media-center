import json
from pathlib import Path

import httpx

from core import tmdb

FIX = Path(__file__).parent / "fixtures"


def fixture(name):
    return json.loads((FIX / name).read_text())


def test_show_hits_tv_endpoint_with_key():
    seen = {}

    def handler(request):
        seen["url"] = str(request.url)
        return httpx.Response(200, json=fixture("tmdb_tv.json"))

    http = httpx.Client(transport=httpx.MockTransport(handler))
    data = tmdb.show("76479", "KEY", http)
    assert data["id"] == 76479
    assert seen["url"].startswith("https://api.themoviedb.org/3/tv/76479?")
    assert "api_key=KEY" in seen["url"]


def test_season_numbers_includes_every_listed_season():
    assert tmdb.season_numbers(fixture("tmdb_tv.json")) == sorted(
        s["season_number"] for s in fixture("tmdb_tv.json")["seasons"]
    )


def test_season_episodes_returns_the_episodes_list():
    http = httpx.Client(
        transport=httpx.MockTransport(
            lambda r: httpx.Response(200, json=fixture("tmdb_season.json"))
        )
    )
    eps = tmdb.season_episodes("76479", 1, "KEY", http)
    assert len(eps) == 3 and eps[0]["episode_number"] == 1


def test_episode_rows_shape():
    rows = tmdb.episode_rows("76479", fixture("tmdb_season.json")["episodes"])
    first = fixture("tmdb_season.json")["episodes"][0]
    assert rows[0]["id"] == str(first["id"])
    assert rows[0]["show_id"] == "76479"
    assert rows[0]["season"] == first["season_number"]
    assert rows[0]["episode"] == first["episode_number"]
    assert rows[0]["title"] == first["name"]
    assert rows[0]["air_date"] == first["air_date"]
    assert rows[0]["runtime_min"] == first["runtime"]
    assert rows[0]["status"] == "Not Started"
    assert rows[0]["updated_at"].endswith("Z")
