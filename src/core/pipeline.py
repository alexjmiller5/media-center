"""Business logic — plain Python, no Modal imports. Runs anywhere."""

import structlog

log = structlog.get_logger()


def run(payload: dict) -> dict:
    log.info("processing", payload=payload)
    # Placeholder: RSS watcher core lands here (see Notion project tasks)
    return {"ok": True, "received": payload}
