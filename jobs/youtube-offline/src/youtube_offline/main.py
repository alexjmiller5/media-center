"""youtube-offline: an outbound long-polling consumer, run by launchd.

youtube-offline watch   reconcile, then long-poll the subscription forever
youtube-offline once    one reconciliation pass, no polling
"""

import sys
import time

import structlog

from .config import Settings, resolve_token
from .hub import Hub, HubError
from .job import Attempts, download, reconcile

log = structlog.get_logger()


def watch(
    hub: Hub,
    settings: Settings,
    attempts: Attempts,
    *,
    fetch=download,
    sleep=time.sleep,
    now=time.time,
    iterations=None,
):
    dirty, backoff = True, 1.0
    while iterations is None or iterations > 0:
        iterations = None if iterations is None else iterations - 1
        try:
            if dirty or attempts.due(now()):
                reconcile(hub, settings, attempts, fetch=fetch, now=now)
                dirty = False
            batch = hub.poll(settings.subscription_id, settings.hold_seconds)
            if batch["events"]:
                # A changed request resets that video's retry budget; the rows
                # decide what to do. ACK only after the pass succeeded.
                for event in batch["events"]:
                    attempts.reset(event["source"]["row_id"])
                attempts.save()
                reconcile(hub, settings, attempts, fetch=fetch, now=now)
                hub.ack(settings.subscription_id, batch["delivery_id"])
            backoff = 1.0
        except HubError as error:
            dirty = True
            delay = min(3600, 3600 if error.credential else error.retry_after or backoff)
            backoff = min(60.0, backoff * 2)
            log.warning("hub", error=str(error), retry_in=delay)
            sleep(delay)
        except Exception as error:  # noqa: BLE001 - the daemon outlives one bad pass
            dirty = True
            log.error("pass failed", error=f"{type(error).__name__}: {error}")
            sleep(30)


def cli(argv: list[str] | None = None) -> int:
    args = argv if argv is not None else sys.argv[1:]
    command = args[0] if args else "--help"
    if command not in ("watch", "once"):
        print(__doc__.strip(), file=sys.stderr)
        return 0 if command in ("-h", "--help") else 2
    structlog.configure(
        processors=[
            structlog.processors.TimeStamper(fmt="iso", utc=True),
            structlog.processors.add_log_level,
            structlog.processors.JSONRenderer(),
        ]
    )
    settings = Settings()
    settings.state_dir.mkdir(parents=True, exist_ok=True)
    hub = Hub(settings.hub_url, lambda: resolve_token(settings))
    attempts = Attempts.load(settings.state_dir)
    if command == "once":
        reconcile(hub, settings, attempts)
    else:
        log.info("watching", hub=settings.hub_url, subscription=settings.subscription_id)
        watch(hub, settings, attempts)
    return 0


if __name__ == "__main__":
    sys.exit(cli())
