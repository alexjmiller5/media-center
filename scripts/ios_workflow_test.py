import unittest
from pathlib import Path


class WorkflowTests(unittest.TestCase):
    def test_workflow_dispatch_encrypts_only_artifact_and_always_cleans_plaintext(self):
        import json
        import subprocess

        workflow = Path(__file__).parents[1] / ".github/workflows/build-ios.yml"
        parsed = json.loads(
            subprocess.check_output(
                [
                    "ruby",
                    "-rjson",
                    "-ryaml",
                    "-e",
                    "puts JSON.generate(YAML.load_file(ARGV[0]))",
                    str(workflow),
                ]
            )
        )
        triggers = parsed.get("on", parsed.get("true"))
        self.assertEqual(set(triggers), {"workflow_dispatch"})
        self.assertTrue(triggers["workflow_dispatch"]["inputs"]["artifact_recipient"]["required"])
        steps = parsed["jobs"]["signed-ipa"]["steps"]
        uploads = [s for s in steps if s.get("uses", "").startswith("actions/upload-artifact@")]
        self.assertEqual(len(uploads), 1)
        self.assertTrue(uploads[0]["with"]["path"].endswith("/App.ipa.age"))
        self.assertNotIn("*", uploads[0]["with"]["path"])
        self.assertEqual(uploads[0]["with"]["retention-days"], 1)
        encrypt = next(s for s in steps if s.get("name") == "Encrypt IPA")
        self.assertIn("age --encrypt", encrypt["run"])
        self.assertNotIn("${{ inputs.", encrypt["run"])
        cleanup = next(s for s in steps if s.get("name") == "Remove plaintext IPA")
        self.assertEqual(cleanup["if"], "always()")
        self.assertIn("unlink", cleanup["run"])

        secrets = next(
            s for s in steps if s.get("uses", "").startswith("1password/load-secrets-action@")
        )
        refs = secrets["env"]
        self.assertNotIn(
            "IOS_PROFILE_BASE64", refs, "the app-specific profile comes from App Store Connect"
        )
        self.assertFalse(any("Wildcard" in str(v) for v in refs.values()))
        self.assertEqual(refs["IOS_DEVICE_ID"], "op://Media Center/Media Center ENV/IOS_DEVICE_ID")
        download = next(s for s in steps if s.get("name") == "Download app-specific Ad Hoc profile")
        self.assertEqual(download["env"]["PROFILE_ID"], "${{ vars.IOS_PROVISIONING_PROFILE_ID }}")
        self.assertIn("IOS_APP_ADHOC", download["run"])
        self.assertIn("::add-mask::", download["run"])
        names = [s.get("name") for s in steps]
        self.assertLess(names.index("Stamp identifiable build"), names.index("Archive and verify"))
        self.assertLess(
            names.index("Archive and verify"), names.index("Verify exported build identity")
        )
        self.assertLess(names.index("Verify exported build identity"), names.index("Encrypt IPA"))


if __name__ == "__main__":
    unittest.main()
