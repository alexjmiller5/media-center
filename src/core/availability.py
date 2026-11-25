"""Country-specific TMDB availability. No titles, personal preferences or credentials are retained."""

from urllib.parse import urlparse

import httpx

BASE = "https://api.themoviedb.org/3"
OFFER_TYPES = {"flatrate": "Subscription", "rent": "Rent", "buy": "Buy"}


class InvalidResponse(ValueError):
    """A consumed provider field is malformed; never publish it as an empty result."""


class Unavailable(Exception):
    """Safe source failure without a credential-bearing URL or remote response body."""


def _integer(value):
    return type(value) is int and value >= 0


def _validate_region(region: str) -> None:
    if (
        not isinstance(region, str)
        or len(region) != 2
        or not region.isascii()
        or not region.isupper()
        or not region.isalpha()
    ):
        raise ValueError("Expected a two-letter country code")


def parse(data: dict, region: str) -> dict:
    _validate_region(region)
    if not isinstance(data, dict) or not isinstance(data.get("results"), dict):
        raise InvalidResponse("Invalid country results")
    if region not in data["results"]:
        return {"result": "Region Missing", "source_url": None, "providers": [], "offers": []}
    entry = data["results"][region]
    if not isinstance(entry, dict) or not isinstance(entry.get("link"), str):
        raise InvalidResponse("Missing watch link")
    link = urlparse(entry["link"])
    if (
        link.scheme != "https"
        or link.hostname not in ("www.themoviedb.org", "themoviedb.org")
        or link.username
        or link.password
        or link.port not in (None, 443)
    ):
        raise InvalidResponse("Invalid watch link")
    providers = {}
    offers = {}
    for source, offer_type in OFFER_TYPES.items():
        rows = entry.get(source, [])
        if not isinstance(rows, list):
            raise InvalidResponse("Invalid provider list")
        for row in rows:
            if not isinstance(row, dict):
                raise InvalidResponse("Invalid provider")
            pid, name, priority, logo = (
                row.get(k)
                for k in ("provider_id", "provider_name", "display_priority", "logo_path")
            )
            if (
                not _integer(pid)
                or pid == 0
                or not isinstance(name, str)
                or not name.strip()
                or not _integer(priority)
                or (
                    logo is not None
                    and (
                        not isinstance(logo, str)
                        or not logo.startswith("/")
                        or logo.startswith("//")
                    )
                )
            ):
                raise InvalidResponse("Invalid provider metadata")
            provider = {"id": str(pid), "name": name, "logo_path": logo}
            if str(pid) in providers and providers[str(pid)] != provider:
                raise InvalidResponse("Conflicting provider metadata")
            providers[str(pid)] = provider
            key = (str(pid), offer_type)
            offer = {
                "provider_id": str(pid),
                "offer_type": offer_type,
                "display_priority": priority,
            }
            if key in offers and offers[key] != offer:
                raise InvalidResponse("Conflicting provider offers")
            offers[key] = offer
    return {
        "result": "Ready",
        "source_url": entry["link"],
        "providers": sorted(providers.values(), key=lambda r: r["id"]),
        "offers": sorted(
            offers.values(),
            key=lambda r: (r["display_priority"], r["provider_id"], r["offer_type"]),
        ),
    }


def fetch(http: httpx.Client, kind: str, identifier: str, key: str, region: str) -> dict:
    _validate_region(region)
    if (
        kind not in ("movie", "tv")
        or not isinstance(identifier, str)
        or not identifier.isascii()
        or not identifier.isdecimal()
        or int(identifier) <= 0
    ):
        raise ValueError("Invalid media identity")
    try:
        response = http.get(
            f"{BASE}/{kind}/{identifier}/watch/providers", params={"api_key": key}, timeout=15
        )
        response.raise_for_status()
        data = response.json()
    except httpx.HTTPStatusError as exc:
        raise Unavailable(f"HTTP {exc.response.status_code}") from None
    except httpx.HTTPError as exc:
        raise Unavailable(type(exc).__name__) from None
    except ValueError:
        raise InvalidResponse("Invalid source JSON") from None
    if not isinstance(data, dict) or str(data.get("id")) != identifier:
        raise InvalidResponse("Source identity mismatch")
    return parse(data, region)
