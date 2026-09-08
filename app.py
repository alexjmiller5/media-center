"""Modal deployment shim — ALL infrastructure lives here, as code.

Business logic stays in src/core/ (plain Python, no Modal imports) so the
same package runs on the mac mini, in tests, or anywhere else. This file
only maps that logic onto Modal: image, secrets, endpoints, schedules.
"""

import modal

APP_NAME = "media-center"  # also the Modal secret name (see justfile sync-secrets)

app = modal.App(APP_NAME)

image = (
    modal.Image.debian_slim(python_version="3.13")
    .uv_sync(extra_options="--no-dev")  # reads pyproject.toml + uv.lock; skip dev group
    # add_local_dir, NOT add_local_python_source: the latter can't resolve
    # packages under src/ layout, and this also carries non-.py data files.
    .add_local_dir("src/core", remote_path="/root/core", ignore=["**/__pycache__"])
)

secrets = [modal.Secret.from_name(APP_NAME)]


@app.function(image=image, secrets=secrets, timeout=600)
def process(payload: dict) -> dict:
    """Background worker — .spawn()ed from the webhook. spawn() IS the queue."""
    from core.pipeline import run

    return run(payload)


@app.function(image=image, secrets=secrets)
@modal.fastapi_endpoint(method="POST", requires_proxy_auth=True)
def webhook(payload: dict) -> dict:
    """HTTP entrypoint. Callers (iPhone Shortcuts) send Modal-Key + Modal-Secret
    headers; unauthorized requests are rejected at Modal's edge, free."""
    call = process.spawn(payload)
    return {"status": "accepted", "call_id": call.object_id}


# ASSUMPTION (2026-07-07 overnight): Modal cron is the intended home for this
# poller per the four-pillar rules, but the Starter plan allows only 5 deployed
# crons across ALL apps — NOT deployed yet; Alex confirms the slot budget first
# (see personal-infra skill). The schedule only claims a slot once deployed.
@app.function(image=image, secrets=secrets, schedule=modal.Cron("30 9 * * *"))
def daily() -> dict:
    from core.pipeline import run

    return run({"trigger": "cron"})


def main() -> None:
    """Run poll-all-sources once, locally (no Modal):

    op run --env-file=.env.tpl -- uv run python app.py
    """
    import sys

    sys.path.insert(0, "src")  # mirrors the image's src/core -> /root/core mapping

    from core.pipeline import poll_all_sources

    print(poll_all_sources())


if __name__ == "__main__":
    main()
