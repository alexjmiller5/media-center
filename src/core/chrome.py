"""Chrome What's New feature cards and their original modal instructions."""

import json
import re
from html.parser import HTMLParser

import httpx

from core.watcher import Entry

SOURCE_URL = "https://www.google.com/chrome/whats-new/archive/"
_FEATURE_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]*")
_VOID = set("area base br col embed hr img input link meta param source track wbr".split())
_SKIP = {"script", "style", "svg", "button", "template", "noscript"}


class _Archive(HTMLParser):
    def __init__(self):
        super().__init__()
        self.cards: dict[str, tuple[str, str]] = {}
        self.modals: dict[str, str] = {}
        # Validate nesting only inside the provider's cards and feature dialogs.
        self.stack: list[str] = []
        self.kind = ""
        self.key = ""
        self.target = ""
        self.blocks: list[str] = []
        self.text: list[str] | None = None
        self.text_depth = 0

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        card_id = attrs.get("data-id") or ""
        modal_id = attrs.get("id") or ""
        is_card = (
            card_id.startswith("card-")
            or "chr-card-simple--feature-2025" in (attrs.get("class") or "").split()
        )
        is_modal = tag == "dialog" and modal_id.endswith("-modal")
        if not self.stack:
            if is_card:
                self.kind, self.key = "card", card_id.removeprefix("card-")
                if (
                    tag != "div"
                    or not card_id.startswith("card-")
                    or not _FEATURE_ID.fullmatch(self.key)
                ):
                    raise ValueError("Chrome card has an invalid feature ID")
            elif is_modal:
                self.kind, self.key = "modal", modal_id
            else:
                return
            self.target, self.blocks = "", []
        elif is_card or is_modal:
            raise ValueError("Chrome feature markup is unexpectedly nested")

        if tag in _VOID:
            if tag == "br" and self.text is not None:
                self.text.append(" ")
            return
        self.stack.append(tag)
        if self.kind == "card" and tag == "button" and "data-props-modaldispatcher" in attrs:
            try:
                props = json.loads(attrs["data-props-modaldispatcher"])
            except (TypeError, ValueError):
                raise ValueError("Chrome feature dispatcher is not valid JSON") from None
            if not isinstance(props, dict) or props.get("id") != f"{self.key}-modal":
                raise ValueError("Chrome feature dispatcher does not match its card ID")
            self.target = props["id"]
        if not _SKIP.isdisjoint(self.stack):
            return
        if (self.kind == "card" and tag == "h3") or (self.kind == "modal" and tag in {"p", "li"}):
            if self.text is None:
                self.text, self.text_depth = [], len(self.stack)
            else:
                self.text.append(" ")

    def handle_data(self, data):
        if self.text is not None and _SKIP.isdisjoint(self.stack):
            self.text.append(data)

    def handle_endtag(self, tag):
        if not self.stack or tag in _VOID:
            return
        if self.stack[-1] != tag:
            raise ValueError("Chrome feature markup has mismatched tags")
        if self.text is not None and self.text_depth == len(self.stack):
            text = " ".join("".join(self.text).split())
            if text:
                self.blocks.append(text)
            self.text = None
        self.stack.pop()
        if self.stack:
            return

        blocks = list(dict.fromkeys(self.blocks))
        if self.kind == "card":
            if len(blocks) != 1 or not self.target:
                raise ValueError("Chrome card must have a title and feature dispatcher")
            card = (blocks[0], self.target)
            if self.key in self.cards and self.cards[self.key] != card:
                raise ValueError("Chrome archive has conflicting duplicate feature cards")
            self.cards[self.key] = card
        else:
            text = "\n\n".join(blocks)
            if self.key in self.modals and self.modals[self.key] != text:
                raise ValueError("Chrome archive has conflicting duplicate feature dialogs")
            self.modals[self.key] = text


def parse_archive(html: str) -> list[Entry]:
    parser = _Archive()
    parser.feed(html)
    # close() turns a buffered unfinished opening tag into ordinary text.
    if parser.rawdata:
        raise ValueError("Chrome archive ends with unfinished markup")
    parser.close()
    if parser.stack or not parser.cards:
        raise ValueError("Chrome archive is incomplete or has no recognized feature cards")
    entries = []
    for feature_id, (title, modal_id) in parser.cards.items():
        text = parser.modals.get(modal_id)
        if not text:
            raise ValueError("Chrome feature is missing its dialog or original instructions")
        url = f"{SOURCE_URL}#{modal_id}"
        entries.append(
            Entry(
                guid=feature_id,
                title=title,
                url=url,
                published=None,
                content={"feature_id": feature_id, "text": text},
                row_id=url,
            )
        )
    return entries


def entries(source_url: str, http: httpx.Client) -> list[Entry]:
    if source_url != SOURCE_URL:
        raise ValueError("Chrome source must be the canonical What's New archive URL")
    response = http.get(source_url, timeout=30, follow_redirects=True)
    response.raise_for_status()
    return parse_archive(response.text)
