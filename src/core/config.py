"""Settings from env vars - Modal Secret in the cloud, `op run` locally.

Instantiate Settings() inside functions, never at import time.
"""

from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    life_hub_url: str
    life_hub_token: str
    tmdb_api_key: str
    youtube_api_key: str
