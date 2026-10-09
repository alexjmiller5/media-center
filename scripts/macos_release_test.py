import json
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).parents[1]


def load(path):
    return json.loads(
        subprocess.check_output(
            [
                "ruby",
                "-rjson",
                "-ryaml",
                "-e",
                "puts JSON.generate(YAML.load_file(ARGV[0]))",
                str(path),
            ]
        )
    )


class ReleaseWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.workflow = load(ROOT / ".github/workflows/release-macos.yml")
        self.text = (ROOT / ".github/workflows/release-macos.yml").read_text()

    def steps(self, job):
        return self.workflow["jobs"][job]["steps"]

    def names(self, job):
        return [s.get("name") for s in self.steps(job)]

    def step(self, job, name):
        return next(s for s in self.steps(job) if s.get("name") == name)

    def test_only_stable_tags_publish(self):
        triggers = self.workflow.get("on", self.workflow.get("true"))
        self.assertEqual(triggers, {"push": {"tags": ["v*"]}})
        self.assertEqual(self.workflow["permissions"], {"contents": "read"})
        self.assertIn(
            r"^v(0|[1-9][0-9]*)\.", self.step("submit", "Validate release inputs")["run"]
        )

    def test_tap_token_never_enters_a_url_or_the_signing_jobs(self):
        self.assertNotIn("x-access-token", self.text)
        self.assertNotIn("@github.com", self.text)
        for job in ("submit", "release"):
            self.assertNotIn("Homebrew Tap Push Token", json.dumps(self.steps(job)))
        checkout = next(
            s for s in self.steps("cask") if s.get("uses", "").startswith("actions/checkout@")
        )
        self.assertEqual(checkout["with"]["token"], "${{ env.TAP_PUSH_TOKEN }}")

    def test_tap_job_is_optional(self):
        cask = self.workflow["jobs"]["cask"]
        self.assertEqual(cask["needs"], "release")
        self.assertEqual(cask["if"], "vars.HOMEBREW_TAP_REPOSITORY != ''")
        self.assertNotIn("TAP_REPOSITORY", self.step("submit", "Validate release inputs")["run"])

    def test_temporary_keychain_restores_the_original_search_list(self):
        sign = self.step("submit", "Sign and verify app")["run"]
        self.assertIn("security list-keychains -d user >", sign)
        cleanup = self.step("submit", "Remove temporary signing material")
        self.assertEqual(cleanup["if"], "always()")
        self.assertIn("security list-keychains -d user -s", cleanup["run"])
        self.assertIn("delete-keychain", cleanup["run"])

    def test_app_specific_profile_and_keychain_gate_precede_submission(self):
        names = self.names("submit")
        for earlier, later in [
            ("Sign and verify app", "Submit signed archive"),
            ("Submit signed archive", "Preserve signed submission"),
        ]:
            self.assertLess(names.index(earlier), names.index(later))
        sign = self.step("submit", "Sign and verify app")["run"]
        self.assertIn("MAC_APP_DIRECT", sign)
        self.assertIn("scripts/verify-macos-signing.py", sign)
        # The signed app's own entitlements and profile must pass a real
        # Data Protection Keychain create/read/update/delete before upload.
        self.assertIn("scripts/test-macos-keychain.sh", sign)
        self.assertLess(
            sign.index("scripts/verify-macos-signing.py"), sign.index("scripts/test-macos-keychain.sh")
        )
        self.assertEqual(
            self.workflow["env"]["PROFILE_ID"], "${{ vars.MACOS_PROVISIONING_PROFILE_ID }}"
        )

    def test_export_options_key_the_profile_by_the_dotted_bundle_id(self):
        sign = self.step("submit", "Sign and verify app")["run"]
        blocks = [b.split("\nPYTHON")[0] for b in sign.split("<<'PYTHON'\n")[1:]]
        script = next(b for b in blocks if "export-options.plist" in b)
        with tempfile.TemporaryDirectory() as root:
            info = Path(root) / "MediaCenter.xcarchive/Products/Applications/MediaCenter.app/Contents"
            info.mkdir(parents=True)
            (info / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.example.media-center"}))
            subprocess.run(["python3", "-", "ABCDE12345", "A" * 40, "uuid-1", root, "MediaCenter"],
                           input=script, text=True, check=True)
            options = plistlib.loads((Path(root) / "export-options.plist").read_bytes())
        self.assertEqual(options, {
            "method": "developer-id", "signingStyle": "manual", "teamID": "ABCDE12345",
            "signingCertificate": "A" * 40,
            "provisioningProfiles": {"com.example.media-center": "uuid-1"},
        })

    def test_submit_uploads_once_and_release_only_waits(self):
        submit = self.step("submit", "Submit signed archive")["run"]
        self.assertIn("notarytool submit", submit)
        self.assertIn("--no-wait", submit)
        self.assertNotIn("notarytool submit", json.dumps(self.steps("release")))
        self.assertIn("notarytool wait", self.step("release", "Wait for existing notarization")["run"])
        preserve = self.step("submit", "Preserve signed submission")
        self.assertEqual(preserve["with"]["if-no-files-found"], "error")
        self.assertEqual(self.workflow["jobs"]["submit"]["outputs"]["artifact_id"],
                         "${{ steps.artifact.outputs.artifact-id }}")

    def test_release_job_rebuilds_nothing_and_verifies_before_publishing(self):
        release = self.workflow["jobs"]["release"]
        self.assertEqual(release["needs"], "submit")
        self.assertEqual(release["permissions"], {"contents": "write"})
        text = json.dumps(self.steps("release"))
        for forbidden in ("xcodebuild", "DEVELOPER_ID_P12", "swift test"):
            self.assertNotIn(forbidden, text)
        names = self.names("release")
        for earlier, later in [
            ("Validate saved submission", "Wait for existing notarization"),
            ("Wait for existing notarization", "Package accepted app"),
            ("Package accepted app", "Publish GitHub release"),
        ]:
            self.assertLess(names.index(earlier), names.index(later))
        package = self.step("release", "Package accepted app")["run"]
        for check in ("stapler staple", "stapler validate", "codesign --verify --deep --strict",
                      "spctl --assess", "SHA256SUMS"):
            self.assertIn(check, package)


if __name__ == "__main__":
    unittest.main()
