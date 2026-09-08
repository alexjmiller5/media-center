"""Modal deployment shim - ALL infrastructure lives here, as code.

Business logic stays in src/core/ (plain Python, no Modal imports). This
file maps it onto Modal: image, secrets, one daily cron. No HTTP endpoints:
nothing calls this app.
"""

import modal

APP_NAME = "media-center"  # also the Modal secret name (see justfile sync-secrets)

app = modal.App(APP_NAME)

image = (
    modal.Image.debian_slim(python_version="3.13")
    .uv_sync(extra_options="--no-dev")
    .add_local_dir("src/core", remote_path="/root/core", ignore=["**/__pycache__"])
)

secrets = [modal.Secret.from_name(APP_NAME)]


def _run() -> dict:
    import httpx

    from core.config import Settings
    from core.hub import HubClient
    from core.pipeline import run_daily

    settings = Settings()
    hub = HubClient(settings.life_hub_url, settings.life_hub_token)
    with httpx.Client(
        timeout=30, follow_redirects=True, headers={"User-Agent": "media-center/0.2"}
    ) as http:
        return run_daily(hub, http, settings)


# Cron slot 3 of the Starter plan's 5 (birthday-reminders, notion-automations
# hold the other two). 09:30 UTC daily; the first run backfills every channel
# and show, hence the long timeout.
@app.function(image=image, secrets=secrets, schedule=modal.Cron("30 9 * * *"), timeout=3600)
def daily() -> dict:
    return _run()


@app.local_entrypoint()
def main() -> None:
    """One run on Modal, on demand: `uv run modal run app.py`."""
    print(daily.remote())
