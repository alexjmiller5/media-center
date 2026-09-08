# /// script
# requires-python = ">=3.12"
# ///
"""Mint this project's machine-creatable credentials (op-project-bootstrap
provision contract: --list prints mintable field names; --field NAME prints
ONLY the secret to stdout, progress on stderr).

Modal has no token-minting API - `modal token new` is a browser flow - so this
minter opens a browser tab ONCE per project and Alex approves it. Bootstrap
already runs in his desktop-authenticated terminal, so that is fine, and the
result is a CI token dedicated to this project: revoking it kills this repo's
deploys and nothing else.

The mint writes to a private temp config (MODAL_CONFIG_PATH) rather than
~/.modal.toml, so no credential lands in the real config; the temp file is
0600 and removed as soon as the second field is read. One browser flow serves
both fields - the second `--field` call reads the file the first one wrote.
"""

import os
import subprocess
import sys
import tempfile
import tomllib
from pathlib import Path

PROJECT = "media-center"  # also the Modal profile name for this project's CI token
FIELDS = {"token-id": "token_id", "token-secret": "token_secret"}
CACHE = Path(tempfile.gettempdir()) / f"modal-ci-{PROJECT}.toml"


def log(msg: str) -> None:
    print(msg, file=sys.stderr)


def modal_bin() -> list[str]:
    """The project's pinned modal, bypassing Alex's PATH wrapper (which would
    inject his personal token and make --verify check the wrong credential)."""
    venv = Path(__file__).resolve().parent.parent / ".venv" / "bin" / "modal"
    return [str(venv)] if venv.exists() else ["uvx", "modal"]


def mint() -> None:
    log(f"· minting a CI-only Modal token for {PROJECT} (a browser tab will open)")
    env = {k: v for k, v in os.environ.items() if k not in ("MODAL_TOKEN_ID", "MODAL_TOKEN_SECRET")}
    env["MODAL_CONFIG_PATH"] = str(CACHE)
    CACHE.touch(mode=0o600)
    subprocess.run(
        [*modal_bin(), "token", "new", "--profile", f"{PROJECT}-ci", "--no-activate"],
        env=env,
        check=True,
        stdout=sys.stderr,
    )


def read(field: str) -> str:
    if not CACHE.exists() or CACHE.stat().st_size == 0:
        mint()
    profiles = tomllib.loads(CACHE.read_text())
    profile = profiles.get(f"{PROJECT}-ci") or next(iter(profiles.values()))
    return profile[FIELDS[field]]


def main() -> None:
    match sys.argv[1:]:
        case ["--list"]:
            print("\n".join(FIELDS))
        case ["--field", name] if name in FIELDS:
            value = read(name)
            # Last field consumed: the temp credential has served its purpose.
            if name == "token-secret":
                CACHE.unlink(missing_ok=True)
            print(value)
        case _:
            sys.exit("usage: provision.py --list | --field <name>")


if __name__ == "__main__":
    main()
