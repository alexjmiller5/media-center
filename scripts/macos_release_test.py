import json
import subprocess
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

    def step(self, job, name):
        return next(s for s in self.steps(job) if s.get("name") == name)

    def test_only_stable_tags_publish(self):
        triggers = self.workflow.get("on", self.workflow.get("true"))
        self.assertEqual(triggers, {"push": {"tags": ["v*"]}})
        self.assertEqual(self.workflow["permissions"], {"contents": "read"})
        self.assertIn(
            r"^v(0|[1-9][0-9]*)\.", self.step("release", "Validate release inputs")["run"]
        )

    def test_tap_token_never_enters_a_url_or_the_signing_job(self):
        self.assertNotIn("x-access-token", self.text)
        self.assertNotIn("@github.com", self.text)
        release_refs = json.dumps(self.steps("release"))
        self.assertNotIn("Homebrew Tap Push Token", release_refs)
        checkout = next(
            s for s in self.steps("cask") if s.get("uses", "").startswith("actions/checkout@")
        )
        self.assertEqual(checkout["with"]["token"], "${{ env.TAP_PUSH_TOKEN }}")

    def test_temporary_keychain_restores_the_original_search_list(self):
        sign = self.step("release", "Sign and verify app")["run"]
        self.assertIn("security list-keychains -d user >", sign)
        cleanup = self.step("release", "Remove temporary signing material")
        self.assertEqual(cleanup["if"], "always()")
        self.assertIn("security list-keychains -d user -s", cleanup["run"])
        self.assertIn("delete-keychain", cleanup["run"])

    def test_app_specific_profile_and_verified_signature_precede_publication(self):
        names = [s.get("name") for s in self.steps("release")]
        for earlier, later in [
            ("Sign and verify app", "Notarize and staple"),
            ("Notarize and staple", "Publish GitHub release"),
        ]:
            self.assertLess(names.index(earlier), names.index(later))
        sign = self.step("release", "Sign and verify app")["run"]
        self.assertIn("MAC_APP_DIRECT", sign)
        self.assertIn("scripts/verify-macos-signing.py", sign)
        self.assertEqual(
            self.workflow["env"]["PROFILE_ID"], "${{ vars.MACOS_PROVISIONING_PROFILE_ID }}"
        )
        self.assertEqual(self.workflow["jobs"]["cask"]["needs"], "release")


if __name__ == "__main__":
    unittest.main()
