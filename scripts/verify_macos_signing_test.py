import datetime
import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "verify", Path(__file__).with_name("verify-macos-signing.py")
)
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)

TEAM, BUNDLE, CERT = "ABCDE12345", "com.example.media", b"leaf"


def profile(**changes):
    value = {
        "ApplicationIdentifierPrefix": [TEAM],
        "TeamIdentifier": [TEAM],
        "Platform": ["OSX"],
        "ProvisionsAllDevices": True,
        "ExpirationDate": datetime.datetime(2999, 1, 1),
        "DeveloperCertificates": [CERT],
        "Entitlements": {
            "com.apple.application-identifier": f"{TEAM}.{BUNDLE}",
            "com.apple.developer.team-identifier": TEAM,
        },
    }
    value.update(changes)
    return value


CLAIMS = {
    "com.apple.application-identifier": f"{TEAM}.{BUNDLE}",
    "com.apple.developer.team-identifier": TEAM,
}


class VerifyClaimsTests(unittest.TestCase):
    def test_accepts_profile_backed_identity(self):
        verify.verify_claims(CLAIMS, profile(), TEAM, BUNDLE, CERT)

    def test_rejects_missing_identity_extra_claims_and_wrong_profiles(self):
        cases = [
            ({}, profile()),
            ({**CLAIMS, "get-task-allow": True}, profile()),
            (CLAIMS, profile(Platform=["iOS"])),
            (CLAIMS, profile(ProvisionsAllDevices=False)),
            (CLAIMS, profile(DeveloperCertificates=[b"other"])),
            (CLAIMS, profile(ExpirationDate=datetime.datetime(2000, 1, 1))),
            (
                CLAIMS,
                profile(
                    Entitlements={
                        "com.apple.application-identifier": f"{TEAM}.other",
                        "com.apple.developer.team-identifier": TEAM,
                    }
                ),
            ),
        ]
        for claims, value in cases:
            with self.assertRaises(ValueError):
                verify.verify_claims(claims, value, TEAM, BUNDLE, CERT)


if __name__ == "__main__":
    unittest.main()
