#!/usr/bin/env python3
"""Archive one iOS app with an existing Ad Hoc identity; never install or publish."""

import argparse
import base64
import hashlib
import json
import os
import plistlib
import re
import secrets
import shlex
import shutil
import signal
import subprocess
import tempfile
import zipfile
from contextlib import ExitStack, contextmanager
from datetime import datetime, timezone
from pathlib import Path


def run(*args, env=None):
    result = subprocess.run([str(a) for a in args], env=env, capture_output=True)
    if result.returncode:
        # Tool diagnostics can contain decoded signing material or device identifiers.
        raise RuntimeError(
            f"{args[0]} failed (exit {result.returncode}); no signing diagnostics emitted"
        )
    return result.stdout


def validate_profile(profile, bundle, device):
    entitlements = profile.get("Entitlements", {})
    expiration = profile.get("ExpirationDate")
    teams = profile.get("TeamIdentifier", [])
    identifier = entitlements.get("application-identifier", "")
    prefix, separator, pattern = identifier.partition(".")
    bundle_matches = "*" not in bundle and (
        pattern == "*"
        or pattern == bundle
        or (pattern.endswith(".*") and "*" not in pattern[:-1] and bundle.startswith(pattern[:-1]))
    )
    if (
        not separator
        or prefix not in profile.get("ApplicationIdentifierPrefix", [])
        or not bundle_matches
    ):
        raise ValueError("Profile does not authorize the app bundle")
    if (
        len(teams) != 1
        or entitlements.get("com.apple.developer.team-identifier") != teams[0]
        or not re.fullmatch(r"[A-Za-z0-9-]+", profile.get("UUID", ""))
    ):
        raise ValueError("Invalid profile team or UUID")
    if not isinstance(expiration, datetime) or expiration.replace(
        tzinfo=timezone.utc
    ) <= datetime.now(timezone.utc):
        raise ValueError("Profile is expired or lacks an expiration")
    if (
        not profile.get("ProvisionedDevices")
        or profile.get("ProvisionsAllDevices")
        or entitlements.get("get-task-allow") is not False
        or not profile.get("DeveloperCertificates")
    ):
        raise ValueError("An Ad Hoc distribution profile with certificates and devices is required")
    if device and device not in profile["ProvisionedDevices"]:
        raise ValueError("Profile does not include the selected device")
    return teams[0], profile["UUID"]


def identity_for_profile(keychain, profile):
    allowed = {hashlib.sha1(cert).hexdigest().upper() for cert in profile["DeveloperCertificates"]}
    identities = run("security", "find-identity", "-v", "-p", "codesigning", keychain).decode()
    for fingerprint in re.findall(
        r'([A-Fa-f0-9]{40}) "(?:Apple|iPhone) Distribution:[^"]+"', identities
    ):
        if fingerprint.upper() in allowed:
            return fingerprint.upper()
    raise ValueError("No valid distribution private-key identity matches the profile")


@contextmanager
def signing_material(p12, password, profile_bytes, uuid, profiles):
    original = shlex.split(run("security", "list-keychains", "-d", "user").decode())
    with tempfile.TemporaryDirectory(prefix="ios-signing-") as temporary, ExitStack() as cleanup:
        root = Path(temporary)
        keychain = root / "signing.keychain-db"
        certificate = root / "certificate.p12"
        certificate.write_bytes(p12)
        certificate.chmod(0o600)
        key_password = secrets.token_urlsafe(32)
        run("security", "create-keychain", "-p", key_password, keychain)
        cleanup.callback(run, "security", "delete-keychain", keychain)
        cleanup.callback(run, "security", "list-keychains", "-d", "user", "-s", *original)
        run("security", "set-keychain-settings", "-lut", "21600", keychain)
        run("security", "unlock-keychain", "-p", key_password, keychain)
        run(
            "security",
            "import",
            certificate,
            "-P",
            password,
            "-A",
            "-t",
            "cert",
            "-f",
            "pkcs12",
            "-k",
            keychain,
        )
        run(
            "security",
            "set-key-partition-list",
            "-S",
            "apple-tool:,apple:,codesign:",
            "-k",
            key_password,
            keychain,
        )
        run("security", "list-keychains", "-d", "user", "-s", keychain, *original)
        profiles.mkdir(parents=True, exist_ok=True)
        installed = profiles / f"{uuid}.mobileprovision"
        with installed.open("xb") as stream:
            cleanup.callback(installed.unlink)
            installed.chmod(0o600)
            stream.write(profile_bytes)
        yield keychain


def validate_entitlements(signed, authorized):
    """Accept scalar claims and arrays authorized by the profile; reject other shapes."""

    def permits(value, grant):
        if type(value) is not type(grant):
            return False
        if isinstance(value, str):
            if "*" in value:
                return False
            return value == grant or (
                grant.endswith("*") and "*" not in grant[:-1] and value.startswith(grant[:-1])
            )
        if isinstance(value, bool):
            return value == grant
        if isinstance(value, list):
            return all(any(permits(entry, allowed) for allowed in grant) for entry in value)
        return False

    for key, value in signed.items():
        if key not in authorized or not permits(value, authorized[key]):
            raise ValueError("Exported entitlement is unauthorized or unsupported")


def extract_certificate(app, prefix):
    run("codesign", "-d", f"--extract-certificates={prefix}", app)
    certificate = Path(str(prefix) + "0")
    run("openssl", "x509", "-inform", "DER", "-in", certificate, "-checkend", "0", "-noout")
    return certificate.read_bytes()


def verify_app(app, bundle, team, fingerprint, device, expected_uuid=None):
    if plistlib.loads((app / "Info.plist").read_bytes())["CFBundleIdentifier"] != bundle:
        raise ValueError("Exported bundle identifier changed")
    profile = plistlib.loads(run("security", "cms", "-D", "-i", app / "embedded.mobileprovision"))
    actual_team, actual_uuid = validate_profile(profile, bundle, device)
    if actual_team != team or (expected_uuid and actual_uuid != expected_uuid):
        raise ValueError("Exported team or provisioning profile changed")
    run("codesign", "--verify", "--deep", "--strict", app)
    entitlements = plistlib.loads(run("codesign", "-d", "--entitlements", ":-", app))
    prefix = profile["Entitlements"]["application-identifier"].partition(".")[0]
    if (
        entitlements.get("application-identifier") != f"{prefix}.{bundle}"
        or entitlements.get("com.apple.developer.team-identifier") != team
        or entitlements.get("get-task-allow", False) is not False
    ):
        raise ValueError("Exported signing entitlements do not match distribution identity")
    validate_entitlements(entitlements, profile["Entitlements"])
    with tempfile.TemporaryDirectory(prefix="ios-cert-") as temporary:
        certificate = extract_certificate(app, Path(temporary) / "certificate")
        if (
            hashlib.sha1(certificate).hexdigest().upper() != fingerprint
            or certificate not in profile["DeveloperCertificates"]
        ):
            raise ValueError("Exported leaf certificate is not the selected profile identity")


def build(project, scheme, output):
    p12 = base64.b64decode(os.environ["IOS_CERTIFICATE_P12_BASE64"], validate=True)
    password = os.environ["IOS_CERTIFICATE_PASSWORD"]
    profile_bytes = base64.b64decode(os.environ["IOS_PROFILE_BASE64"], validate=True)
    device = os.environ.get("IOS_DEVICE_ID") or None
    base = ["xcodebuild", "-project", project, "-scheme", scheme, "-configuration", "Release"]
    settings = json.loads(run(*base, "-sdk", "iphoneos", "-showBuildSettings", "-json"))
    apps = [
        entry["buildSettings"]
        for entry in settings
        if entry["buildSettings"].get("WRAPPER_EXTENSION") == "app"
    ]
    if len(apps) != 1:
        raise ValueError("Exactly one application target is supported")
    bundle = apps[0]["PRODUCT_BUNDLE_IDENTIFIER"]
    with tempfile.TemporaryDirectory(prefix="ios-archive-") as temporary:
        root = Path(temporary)
        source_profile = root / "source.mobileprovision"
        source_profile.write_bytes(profile_bytes)
        profile = plistlib.loads(run("security", "cms", "-D", "-i", source_profile))
        team, uuid = validate_profile(profile, bundle, device)
        profiles = Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles"
        with signing_material(p12, password, profile_bytes, uuid, profiles) as keychain:
            fingerprint = identity_for_profile(keychain, profile)
            env = dict(os.environ, IOS_PROFILE=uuid)
            # IOS_PROFILE is referenced only on the app target in project.yml.
            archive = root / "App.xcarchive"
            run(
                *base,
                "-destination",
                "generic/platform=iOS",
                "-archivePath",
                archive,
                "-derivedDataPath",
                root / "DerivedData",
                "CODE_SIGN_STYLE=Manual",
                f"DEVELOPMENT_TEAM={team}",
                f"CODE_SIGN_IDENTITY={fingerprint}",
                f"IOS_PROFILE={uuid}",
                f"OTHER_CODE_SIGN_FLAGS=--keychain {shlex.quote(str(keychain))}",
                "archive",
                env=env,
            )
            export_options = root / "ExportOptions.plist"
            export_options.write_bytes(
                plistlib.dumps(
                    {
                        "method": "release-testing",
                        "signingStyle": "manual",
                        "teamID": team,
                        "signingCertificate": fingerprint,
                        "provisioningProfiles": {bundle: uuid},
                        "manageAppVersionAndBuildNumber": False,
                    }
                )
            )
            exported = root / "export"
            run(
                "xcodebuild",
                "-exportArchive",
                "-archivePath",
                archive,
                "-exportOptionsPlist",
                export_options,
                "-exportPath",
                exported,
            )
            ipas = list(exported.glob("*.ipa"))
            if len(ipas) != 1:
                raise ValueError("Expected exactly one exported IPA")
            extracted = root / "extracted"
            with zipfile.ZipFile(ipas[0]) as ipa:
                if any(Path(n).is_absolute() or ".." in Path(n).parts for n in ipa.namelist()):
                    raise ValueError("Unsafe exported IPA path")
            run("ditto", "-x", "-k", ipas[0], extracted)
            apps = list((extracted / "Payload").glob("*.app"))
            if len(apps) != 1:
                raise ValueError("Expected exactly one exported app")
            verify_app(apps[0], bundle, team, fingerprint, device, uuid)
            output = Path(output)
            output.mkdir(parents=True, exist_ok=True)
            destination = output / "App.ipa"
            if destination.exists():
                raise FileExistsError("Refusing to overwrite an existing IPA")
            shutil.copyfile(ipas[0], destination)
            destination.chmod(0o600)
    print("Verified Ad Hoc IPA written; signing material cleaned up.")
    print("IPA SHA256: " + hashlib.sha256(destination.read_bytes()).hexdigest())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", required=True)
    parser.add_argument("--scheme", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(SystemExit(143)))
    try:
        build(args.project, args.scheme, args.output)
    except (KeyError, ValueError, RuntimeError, OSError) as error:
        # Do not stringify arbitrary subprocess exceptions or their secret-bearing argv.
        print(
            f"Signing failed: {type(error).__name__}. No signing material published.",
            file=__import__("sys").stderr,
        )
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
