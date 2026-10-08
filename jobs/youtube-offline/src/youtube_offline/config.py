"""Settings from the caller environment (YOUTUBE_OFFLINE_*), resolved at start.

The credential seam: YOUTUBE_OFFLINE_HUB_TOKEN (literal) or
YOUTUBE_OFFLINE_TOKEN_COMMAND (a JSON argv whose stdout is the token). The job
never knows which secret store its caller uses.
"""

import os
import subprocess
from pathlib import Path
from urllib.parse import urlsplit

from pydantic import Field, SecretStr, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

# 720p cap, mp4. H.264 first: AVFoundation decodes AV1 only in hardware on recent
# chips, so offline copies must play on any Apple device. Then any mp4, then remux.
DEFAULT_FORMAT = (
    "bv*[height<=720][vcodec^=avc1]+ba[ext=m4a]/b[height<=720][vcodec^=avc1]"
    "/bv*[height<=720][ext=mp4]+ba[ext=m4a]/b[height<=720][ext=mp4]"
    "/bv*[height<=720]+ba/b[height<=720]"
)


class CredentialError(Exception):
    pass


def default_state_dir() -> Path:
    base = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local/state")
    return base / "media-center" / "youtube-offline"


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="YOUTUBE_OFFLINE_", hide_input_in_errors=True)

    hub_url: str
    subscription_id: str
    hub_token: SecretStr | None = None
    token_command: list[str] | None = None
    state_dir: Path = Field(default_factory=default_state_dir)
    hold_seconds: int = Field(default=30, ge=0, le=30)
    # Total bytes of retained videos; new downloads are refused at the cap.
    storage_cap_bytes: int = Field(default=5_000_000_000, ge=0)
    # Each upload is one hub request; Cloudflare caps request bodies at 100 MB.
    part_bytes: int = Field(default=90 * 1024 * 1024, ge=1024 * 1024, le=95_000_000)
    format: str = DEFAULT_FORMAT
    yt_dlp: str = "yt-dlp"

    @field_validator("hub_url")
    @classmethod
    def https_origin(cls, value: str) -> str:
        url = urlsplit(value)
        if (
            url.scheme != "https"
            or not url.hostname
            or url.username is not None
            or url.password is not None
            or url.path not in ("", "/")
            or url.query
            or url.fragment
        ):
            raise ValueError("hub_url must be an HTTPS origin without credentials")
        return value.rstrip("/")


def resolve_token(settings: Settings) -> str:
    if settings.hub_token:
        return settings.hub_token.get_secret_value()
    if not settings.token_command:
        raise CredentialError(
            "no credential: set YOUTUBE_OFFLINE_HUB_TOKEN or YOUTUBE_OFFLINE_TOKEN_COMMAND"
        )
    try:
        result = subprocess.run(
            settings.token_command, capture_output=True, text=True, timeout=30, check=False
        )
    except (OSError, subprocess.TimeoutExpired):
        raise CredentialError("token command could not run") from None
    token = result.stdout.strip()
    if result.returncode != 0 or not token:
        raise CredentialError("token command failed")
    return token
