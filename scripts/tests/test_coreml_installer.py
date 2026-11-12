import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

path = Path(__file__).resolve().parents[1] / "install_coreml_artifacts.py"
spec = importlib.util.spec_from_file_location("installer", path)
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class CoreMLInstallerTests(unittest.TestCase):
    def fixture(self, root):
        folder = root / "acne.mlpackage"; folder.mkdir()
        data = b"synthetic model bytes, not real weights"
        (folder / "model.bin").write_bytes(data)
        file = {"relativePath": "models/acne/acne.mlpackage/model.bin", "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
        record = {"id": "acne", "package": "models/acne/acne.mlpackage", "repository": "author/model", "revision": "a"*40,
                  "modelSHA256": "b"*64, "inputName": "image", "outputName": "logits", "inputSize": 224, "files": [file]}
        lock = {"schema": 1, "models": [{"id": "acne", "model": copy.deepcopy(record)}]}
        specs = {"acne": {"id": "acne", "repo": "author/model", "revision": "a"*40,
                           "files": [{"name": "model.safetensors", "sha256": "b"*64}]}}
        record["installedFiles"] = installer.installed_files(record)
        self.write_manifest(root, [record])
        return lock, specs, record

    @staticmethod
    def write_manifest(root, records):
        (root / "coreml-model-manifest.json").write_text(json.dumps({"schema": 1, "models": records}))

    def test_verified_installed_package(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); lock, specs, _ = self.fixture(root)
            installer.verify_installed(root, lock, specs)

    def test_corruption_and_coherent_manifest_tampering_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); lock, specs, record = self.fixture(root)
            (root / "acne.mlpackage/model.bin").write_bytes(b"modified")
            record["installedFiles"][0].update(bytes=8, sha256=hashlib.sha256(b"modified").hexdigest())
            self.write_manifest(root, [record])
            with self.assertRaisesRegex(ValueError, "differs_from_approved_pin"):
                installer.verify_installed(root, lock, specs)

    def test_stale_revision_duplicate_id_and_extra_files_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); lock, specs, record = self.fixture(root)
            record["revision"] = "stale"
            self.write_manifest(root, [record])
            with self.assertRaises(ValueError): installer.verify_installed(root, lock, specs)
            self.write_manifest(root, [record, record])
            with self.assertRaises(ValueError): installer.verify_installed(root, lock, specs)
            record["revision"] = "a"*40; self.write_manifest(root, [record])
            (root / "acne.mlpackage/extra.py").write_text("not permitted")
            with self.assertRaisesRegex(ValueError, "extra_installed_file"): installer.verify_installed(root, lock, specs)

    def test_traversal_symlink_and_entry_budget_rejected(self):
        for name, mode in [("../outside", None), ("C:\\outside", None), ("link", 0o120777)]:
            with self.subTest(name=name), io.BytesIO() as data:
                with zipfile.ZipFile(data, "w") as archive:
                    info = zipfile.ZipInfo(name)
                    if mode: info.external_attr = mode << 16
                    archive.writestr(info, b"x")
                data.seek(0)
                with zipfile.ZipFile(data) as archive, self.assertRaises(ValueError): list(installer.safe_files(archive))
        with io.BytesIO() as data:
            with zipfile.ZipFile(data, "w") as archive:
                for i in range(201): archive.writestr(str(i), b"")
            data.seek(0)
            with zipfile.ZipFile(data) as archive, self.assertRaises(ValueError): list(installer.safe_files(archive))

    def test_stream_budget_enforced_before_oversized_write(self):
        destination = io.BytesIO()
        with self.assertRaisesRegex(ValueError, "budget_exceeded"):
            installer.copy_bounded(io.BytesIO(b"x"*100), destination, 10)
        self.assertLessEqual(len(destination.getvalue()), 10)
        destination = io.BytesIO()
        self.assertEqual(installer.copy_bounded(io.BytesIO(b"x"*10), destination, 10), 10)


if __name__ == "__main__": unittest.main()
