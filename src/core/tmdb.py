"""TMDB season listings for tv_episodes rows. Plain Python, no Modal."""

import httpx

from core.hub import now_iso

BASE = "https://api.themoviedb.org/3"


def show(show_id: str, key: str, http: httpx.Client) -> dict:
    resp = http.get(f"{BASE}/tv/{show_id}", params={"api_key": key}, timeout=15)
    resp.raise_for_status()
    return resp.json()


def season_numbers(show_json: dict) -> list[int]:
    return sorted(s["season_number"] for s in show_json.get("seasons") or [])


def season_episodes(show_id: str, n: int, key: str, http: httpx.Client) -> list[dict]:
    resp = http.get(f"{BASE}/tv/{show_id}/season/{n}", params={"api_key": key}, timeout=15)
    resp.raise_for_status()
    return resp.json().get("episodes") or []


def episode_rows(show_id: str, episodes: list[dict]) -> list[dict]:
    stamp = now_iso()
    return [
        {
            "id": str(e["id"]),
            "show_id": show_id,
            "season": e["season_number"],
            "episode": e["episode_number"],
            "title": e.get("name"),
            "air_date": e.get("air_date"),
            "runtime_min": e.get("runtime"),
            "status": "Not Started",
            "updated_at": stamp,
        }
        for e in episodes
    ]
