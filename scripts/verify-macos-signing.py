#!/usr/bin/env python3
"""Verify a Developer ID export: profile-backed private Keychain identity in every architecture."""

import datetime
import fnmatch
import hashlib
import plistlib
import re
import subprocess
import sys
import tempfile
from pathlib import Path


def verify_claims(claims, profile, team, bundle, certificate):
    def require(condition, message):
        if not condition:
            raise ValueError(message)

    prefix = profile.get("ApplicationIdentifierPrefix", [])
    require(len(prefix) == 1, "Profile must have one App ID prefix")
    app_id = prefix[0] + "." + bundle
    require(
        claims
        == {
            "com.apple.application-identifier": app_id,
            "com.apple.developer.team-identifier": team,
        },
        "App must claim only its profile-backed private identity",
    )
    require(profile.get("TeamIdentifier") == [team], "Profile team mismatch")
    require(profile.get("Platform") == ["OSX"], "Profile is not for macOS")
    require(profile.get("ProvisionsAllDevices") is True, "Profile is not direct distribution")
    expires = profile.get("ExpirationDate", datetime.datetime.min)
    require(expires > datetime.datetime.now(datetime.UTC).replace(tzinfo=None), "Profile expired")
    require(
        certificate in profile.get("DeveloperCertificates", []),
        "Profile does not authorize the signing certificate",
    )
    allowed = profile.get("Entitlements", {})
    require(
        allowed.get("com.apple.developer.team-identifier") == team,
        "Profile entitlement team mismatch",
    )
    require(
        fnmatch.fnmatchcase(app_id, allowed.get("com.apple.application-identifier", "")),
        "Profile does not authorize the app ID",
    )
    require(not allowed.get("get-task-allow"), "Development profile is not distributable")


def main(app, team, certificate_sha1):
    app = Path(app)
    bundle = plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleIdentifier"]
    profile = plistlib.loads(
        subprocess.check_output(
            ["security", "cms", "-D", "-i", str(app / "Contents/embedded.provisionprofile")],
            stderr=subprocess.DEVNULL,
        )
    )
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    for arch in ("arm64", "x86_64"):
        details = subprocess.run(
            ["codesign", "-d", "--verbose=4", "--arch", arch, str(app)],
            check=True,
            capture_output=True,
            text=True,
        ).stderr
        if (
            not re.search(r"^TeamIdentifier=" + re.escape(team) + "$", details, re.M)
            or "runtime" not in details
        ):
            raise ValueError(f"{arch}: signed team or hardened runtime does not match")
        with tempfile.TemporaryDirectory() as scratch:
            prefix = str(Path(scratch) / "certificate")
            subprocess.run(
                ["codesign", "-d", "--arch", arch, "--extract-certificates=" + prefix, str(app)],
                check=True,
                capture_output=True,
            )
            certificate = Path(prefix + "0").read_bytes()
        if hashlib.sha1(certificate).hexdigest().upper() != certificate_sha1.upper():
            raise ValueError(f"{arch}: export did not use the selected certificate")
        claims = plistlib.loads(
            subprocess.check_output(
                ["codesign", "-d", "--arch", arch, "--entitlements", "-", "--xml", str(app)],
                stderr=subprocess.DEVNULL,
            )
        )
        verify_claims(claims, profile, team, bundle, certificate)
    print("Both architectures carry the profile-authorized private Keychain identity")


if __name__ == "__main__":
    main(*sys.argv[1:])
