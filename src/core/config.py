"""Settings from env vars — Modal Secret in the cloud, `op run` locally.

One field per line in .env.tpl. Instantiate Settings() inside functions,
not at import time, so tests can run without secrets.
"""

from typing import Annotated

from pydantic import field_validator
from pydantic_settings import BaseSettings, NoDecode


class Settings(BaseSettings):
    notion_api_key: str
    # Comma-separated Notion data_source IDs of the source DBs to poll.
    source_dbs: Annotated[tuple[str, ...], NoDecode]

    @field_validator("source_dbs", mode="before")
    @classmethod
    def _split_csv(cls, v: object) -> object:
        if isinstance(v, str):
            return tuple(part.strip() for part in v.split(",") if part.strip())
        return v
