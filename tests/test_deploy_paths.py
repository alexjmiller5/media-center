"""Poller deployment stays independent of native client changes."""

import fnmatch
import json
import re
from pathlib import Path


def test_poller_deploy_requires_service_changes():
    workflow = Path(".github/workflows/deploy.yml").read_text()
    match = re.search(r"(?m)^    paths: (\[.*\])$", workflow)
    assert match, "Poller deploy must declare push paths"
    paths = json.loads(match[1])
    for changed in (
        "app.py",
        "src/core/pipeline.py",
        "pyproject.toml",
        "uv.lock",
        ".env.tpl",
        "scripts/sync_secrets.py",
        ".github/workflows/deploy.yml",
    ):
        assert any(fnmatch.fnmatchcase(changed, pattern) for pattern in paths), changed
    for changed in (
        "apps/Shared/MediaCenterRoot.swift",
        "packages/MediaKit/Sources/MediaKit/MediaLibrary.swift",
        "README.md",
        "docs/superpowers/specs/2026-10-07-native-media-center-design.md",
        ".github/workflows/native-check.yml",
        "scripts/build-enrollment-policy.ts",
        "flake.nix",
    ):
        assert not any(fnmatch.fnmatchcase(changed, pattern) for pattern in paths), changed
