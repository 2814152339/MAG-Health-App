"""Offline routing-only rename checks; no GitHub requests or app/resource writes."""
import copy
import importlib.util
import json
from pathlib import Path
import re
import unittest


PROJECT = Path(__file__).resolve().parents[2]
CURRENT_REPOSITORY = "2814152339/MAG-Health-App"
HISTORICAL_REPOSITORY = "2814152339/ruyuan-aesthetics-ios"


def load_script(name, filename):
    spec = importlib.util.spec_from_file_location(name, PROJECT / "scripts" / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


installer = load_script("rename_installer", "install_coreml_artifacts.py")
publisher = load_script("rename_publisher", "publish_coreml_release.py")


class RepositoryRenameTests(unittest.TestCase):
    def test_new_repository_routes_agree_and_old_release_source_is_rejected(self):
        self.assertEqual(installer.REPO, CURRENT_REPOSITORY)
        self.assertEqual(publisher.REPOSITORY, CURRENT_REPOSITORY)
        workflow = (PROJECT / ".github/workflows/publish-coreml-models.yml").read_text(encoding="utf-8")
        guards = re.findall(
            r"^\s*if:\s*\$\{\{\s*github\.repository\s*==\s*(['\"])([^'\"]+)\1\s*\}\}\s*$",
            workflow, re.MULTILINE,
        )
        self.assertEqual([repository for _, repository in guards], [CURRENT_REPOSITORY])
        self.assertNotIn(HISTORICAL_REPOSITORY, workflow)

        lock = json.loads(installer.LOCK.read_text(encoding="utf-8"))
        # The rename may change endpoints, never the already-verified model ZIPs.
        originals = {
            "acne": (737665562, 171760926, "551572974ab446bb8b75c08977aecee5a45a300eb40a5254da93311b05d3d7a8"),
            "wrinkles": (737666107, 171755190, "eefb370269289c023b951bce1fc3c15167403eee0dad3ce277d9798848305c3d"),
            "skin_type": (737666476, 343344789, "a8f5d7231fa319c2619ff02bc2be268171ed3a2a9642357a2aeeec92ee5110ef"),
        }
        self.assertEqual(len(lock["models"]), 3)
        self.assertEqual({pin["id"] for pin in lock["models"]}, set(originals))
        for pin in lock["models"]:
            with self.subTest(model=pin["id"]):
                asset_id, archive_bytes, archive_hash = originals[pin["id"]]
                suffix = f"/releases/assets/{asset_id}"
                self.assertEqual(pin["releaseAssetID"], asset_id)
                self.assertEqual(pin["releaseID"], 442401296)
                self.assertEqual(pin["releaseTag"], "coreml-models-20261112-v1")
                self.assertEqual(pin["archiveBytes"], archive_bytes)
                self.assertEqual(pin["archiveSHA256"], archive_hash)
                self.assertEqual(pin["source"], {
                    "type": "githubRelease", "repository": CURRENT_REPOSITORY,
                    "tag": pin["releaseTag"], "releaseID": pin["releaseID"],
                    "assetID": asset_id, "assetName": f"Ruyuan-CoreML-{pin['id']}.zip",
                    "apiURL": f"https://api.github.com/repos/{CURRENT_REPOSITORY}{suffix}",
                })
                self.assertEqual(installer.archive_source(pin), ("release", suffix))
                old_pin = copy.deepcopy(pin)
                old_pin["source"]["repository"] = HISTORICAL_REPOSITORY
                old_pin["source"]["apiURL"] = f"https://api.github.com/repos/{HISTORICAL_REPOSITORY}{suffix}"
                with self.assertRaisesRegex(ValueError, "release_source_identity_mismatch"):
                    installer.archive_source(old_pin)

    def test_original_private_publication_receipt_remains_historical(self):
        lock = json.loads(installer.LOCK.read_text(encoding="utf-8"))
        # These describe the actual pre-rename verification, not a new public release check.
        self.assertEqual(lock["publication"], {
            "state": "private_release_assets_fully_verified",
            "repository": HISTORICAL_REPOSITORY,
            "tag": "coreml-models-20261112-v1",
            "releaseID": 442401296,
            "sourceLockSHA256": "26cf4608620672c302da5ce8ea1c961b63b4e4ca03b0f4938e220194f2e55883",
            "verifiedAt": "2026-11-12T01:56:53.925697+00:00",
            "repositoryPrivateAtVerification": True,
        })


if __name__ == "__main__":
    unittest.main()
