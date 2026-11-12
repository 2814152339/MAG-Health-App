"""Offline Release transport/install regressions. Synthetic bytes only; no GitHub writes."""
import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import urllib.error
import zipfile

SCRIPT = Path(__file__).resolve().parents[1]/"install_coreml_artifacts.py"
SPEC = importlib.util.spec_from_file_location("release_installer", SCRIPT)
installer = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(installer)
PROJECT = installer.ROOT


def checksum(data): return hashlib.sha256(data).hexdigest()


def zipped(files):
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_STORED) as archive:
        for name, data in files.items(): archive.writestr(name, data)
    return output.getvalue()


class Response(io.BytesIO):
    def __enter__(self): return self
    def __exit__(self, *args): self.close()


def fixture(root, release=True):
    records = []; specs = []; bodies = {}; package_files = {}
    for index, key in enumerate(("acne", "wrinkles", "skin_type")):
        package = f"models/{key}/{key}.mlpackage"
        path = package+"/weights.bin"
        weights = ("synthetic-public-model-"+key).encode()
        model = {"id":key, "repository":"author/"+key, "revision":"a"*40, "modelSHA256":"b"*64,
                 "package":package, "inputName":"image", "outputName":"logits", "inputSize":224,
                 "files":[{"relativePath":path, "bytes":len(weights), "sha256":checksum(weights)}]}
        files = {path:weights,
                 "model-manifest.json":json.dumps({"schema":1,"state":"converted_and_coreml_cpu_verified","models":[model]}).encode(),
                 f"models/{key}/source-notices/README.md":b"synthetic author notice",
                 f"models/{key}/source-notices/source.json":b"{}"}
        inner = zipped(files)
        pin = {"id":key, "runID":100+index, "artifactID":200+index, "archiveBytes":len(inner),
               "archiveSHA256":checksum(inner), "model":copy.deepcopy(model), "validation":{"synthetic":True}}
        if release:
            pin.update(releaseAssetID=500+index, releaseID=7, releaseTag="fixture-models-v1")
            pin["source"] = {"type":"githubRelease", "repository":installer.REPO, "assetID":500+index,
                "releaseID":7, "tag":"fixture-models-v1", "assetName":f"Ruyuan-CoreML-{key}.zip",
                "apiURL":f"https://api.github.com/repos/{installer.REPO}/releases/assets/{500+index}"}
            suffix = f"/releases/assets/{500+index}"; bodies[suffix] = inner
        else:
            suffix = f"/actions/artifacts/{200+index}/zip"
            bodies[suffix] = zipped({f"Ruyuan-CoreML-{key}.zip":inner})
        records.append(pin); package_files[key] = files
        specs.append({"id":key,"repo":"author/"+key,"revision":"a"*40,
                      "files":[{"name":"model.safetensors","sha256":"b"*64}]})
    lock = {"schema":1,"models":records}
    backend = root/"backend/ruyuan"; backend.mkdir(parents=True)
    (backend/"skin_model_manifest.json").write_text(json.dumps({"models":specs}))
    lock_path = root/"candidate-lock.json"; lock_path.write_text(json.dumps(lock))
    destination = root/"iOS/Ruyuan/Resources/CoreML"
    return lock, lock_path, destination, bodies, package_files


class ReleaseInstallerTests(unittest.TestCase):
    def temporary(self):
        (PROJECT/".build").mkdir(exist_ok=True)
        return tempfile.TemporaryDirectory(prefix="release-installer-tests-", dir=PROJECT/".build")

    def test_legacy_and_release_source_selection_never_authenticates_lock_url(self):
        self.assertEqual(installer.archive_source({"artifactID":7}), ("actions", "/actions/artifacts/7/zip"))
        self.assertEqual(installer.archive_source({"artifactID":7,"releaseAssetID":8}), ("release", "/releases/assets/8"))
        for bad in [True, 0, -1, "8", None]:
            with self.subTest(bad=bad), self.assertRaisesRegex(ValueError, "invalid_release_asset_id"):
                installer.archive_source({"artifactID":7, "releaseAssetID":bad})
        with self.temporary() as folder:
            lock, _, _, _, _ = fixture(Path(folder))
            pin = lock["models"][0]
            self.assertEqual(installer.archive_source(pin), ("release", "/releases/assets/500"))
            for field, value in [("repository","other/repo"), ("assetID",501), ("apiURL","https://evil.test/steal"),
                                 ("releaseID",8), ("tag","wrong"), ("assetName","private-photo.zip")]:
                invalid = copy.deepcopy(pin); invalid["source"][field] = value
                with self.subTest(field=field), self.assertRaisesRegex(ValueError, "identity_mismatch"):
                    installer.archive_source(invalid)

    def test_direct_release_200_uses_octet_stream_only_on_fixed_github_api(self):
        requests = []
        class Transport:
            def open(self, request, **kwargs): requests.append(request); return Response(b"direct bytes")
        with mock.patch.object(installer.urllib.request, "build_opener", return_value=Transport()):
            with installer.github_binary_response("/releases/assets/123", "unit-test-not-a-real-token") as response:
                self.assertEqual(response.read(), b"direct bytes")
        self.assertEqual(requests[0].full_url, "https://api.github.com/repos/"+installer.REPO+"/releases/assets/123")
        self.assertEqual(requests[0].get_header("Accept"), "application/octet-stream")
        self.assertEqual(requests[0].get_header("Authorization"), "Bearer unit-test-not-a-real-token")
        with self.assertRaises(ValueError): installer.github_binary_response("https://evil.test/", "not-a-real-token")

    def test_actions_zip_uses_json_accept_instead_of_release_octet_stream(self):
        requests = []
        class Transport:
            def open(self, request, **kwargs): requests.append(request); return Response(b"action outer zip")
        with mock.patch.object(installer.urllib.request, "build_opener", return_value=Transport()):
            with installer.github_binary_response("/actions/artifacts/456/zip", "not-a-real-token") as response:
                self.assertEqual(response.read(), b"action outer zip")
        self.assertEqual(requests[0].get_header("Accept"), "application/vnd.github+json")

    def test_every_signed_storage_redirect_has_no_authorization(self):
        api_requests = []; storage_requests = []
        class API:
            def open(self, request, **kwargs):
                api_requests.append(request)
                raise urllib.error.HTTPError(request.full_url, 302, "not logged", {"Location":"https://release-assets.githubusercontent.com/first?sig=unit"}, None)
        class Storage:
            def open(self, request, **kwargs):
                storage_requests.append(request)
                if len(storage_requests) == 1:
                    raise urllib.error.HTTPError(request.full_url, 307, "not logged", {"Location":"/second?sig=unit"}, None)
                return Response(b"abc")
        with mock.patch.object(installer.urllib.request, "build_opener", side_effect=[API(), Storage()]):
            with installer.github_binary_response("/releases/assets/123", "not-a-real-token") as response:
                self.assertEqual(response.read(), b"abc")
        self.assertEqual(len(api_requests), 1)
        self.assertEqual(len(storage_requests), 2)
        for request in storage_requests:
            self.assertNotIn("Authorization", dict(request.header_items()))
            self.assertNotIn("Cookie", dict(request.header_items()))

    def test_unapproved_or_malformed_storage_url_is_rejected_before_request(self):
        urls = ["http://release-assets.githubusercontent.com/a", "https://api.github.com/a", "https://evil.test/a",
                "https://production.blob.core.windows.net.evil.test/a", "https://user:secret@release-assets.githubusercontent.com/a",
                "https://release-assets.githubusercontent.com:444/a", "https://release-assets.githubusercontent.com:bad/a",
                "https://127.0.0.1/a", "https://release-assets.githubusercontent.com/a#fragment"]
        transport = mock.Mock()
        with mock.patch.object(installer.urllib.request, "build_opener", return_value=transport):
            for url in urls:
                with self.subTest(url=url), self.assertRaisesRegex(RuntimeError, "unapproved"):
                    installer.unsigned_response(url)
        transport.open.assert_not_called()

    def test_storage_redirect_to_unapproved_host_is_not_followed(self):
        requests = []
        class Storage:
            def open(self, request, **kwargs):
                requests.append(request)
                raise urllib.error.HTTPError(request.full_url, 302, "secret ignored", {"Location":"https://evil.test/steal"}, None)
        with mock.patch.object(installer.urllib.request, "build_opener", return_value=Storage()):
            with self.assertRaisesRegex(RuntimeError, "unapproved"):
                installer.unsigned_response("https://release-assets.githubusercontent.com/a")
        self.assertEqual(len(requests), 1)

    def test_network_errors_do_not_include_token_signed_url_or_server_reason(self):
        secret = "unit-secret-reason-DO-NOT-LOG"
        class Transport:
            def open(self, request, **kwargs):
                raise urllib.error.HTTPError(request.full_url, 403, secret, {}, None)
        with mock.patch.object(installer.urllib.request, "build_opener", return_value=Transport()):
            for call in [lambda: installer.github_binary_response("/releases/assets/123", secret),
                         lambda: installer.unsigned_response("https://release-assets.githubusercontent.com/a?sig="+secret)]:
                with self.assertRaises(RuntimeError) as error: call()
                self.assertNotIn(secret, str(error.exception))
                self.assertNotIn("https", str(error.exception))
        class BrokenResponse(Response):
            def read(self, *args): raise urllib.error.URLError(secret)
        with self.temporary() as folder, mock.patch.object(installer, "github_binary_response", return_value=BrokenResponse(b"")):
            with self.assertRaisesRegex(RuntimeError, "model_download_stream_failed") as error:
                installer.download_archive("/releases/assets/123", secret, Path(folder)/"model.zip", 10)
            self.assertNotIn(secret, str(error.exception))

    def test_installs_release_inner_zip_without_actions_wrapper_and_check_is_offline(self):
        with self.temporary() as folder:
            root = Path(folder); lock, lock_path, destination, bodies, _ = fixture(root)
            calls = []
            def response(suffix, token): calls.append(suffix); return Response(bodies[suffix])
            with mock.patch.multiple(installer, ROOT=root, DEST=destination), mock.patch.dict(installer.os.environ, {"GITHUB_TOKEN":"not-a-real-token"}), \
                 mock.patch.object(installer, "github_binary_response", side_effect=response):
                installer.install(lock_path)
                self.assertEqual(calls, ["/releases/assets/500", "/releases/assets/501", "/releases/assets/502"])
                with mock.patch.object(installer, "github_binary_response", side_effect=AssertionError("--check must not access network")):
                    installer.install(lock_path, check=True)
            self.assertTrue((destination/"acne.mlpackage/weights.bin").is_file())
            self.assertTrue((destination/"source-notices/skin_type/README.md").is_file())
            self.assertEqual(json.loads(lock_path.read_text()), lock, "Installation never writes the candidate/formal lock")

    def test_legacy_actions_outer_zip_install_remains_compatible(self):
        with self.temporary() as folder:
            root = Path(folder); _, lock_path, destination, bodies, _ = fixture(root, release=False)
            with mock.patch.multiple(installer, ROOT=root, DEST=destination), mock.patch.dict(installer.os.environ, {"GITHUB_TOKEN":"not-a-real-token"}), \
                 mock.patch.object(installer, "github_binary_response", side_effect=lambda suffix, token: Response(bodies[suffix])):
                installer.install(lock_path)
                installer.install(lock_path, check=True)
            self.assertTrue((destination/"skin_type.mlpackage/weights.bin").is_file())

    def test_release_failure_has_no_actions_fallback_and_keeps_prior_resources(self):
        with self.temporary() as folder:
            root = Path(folder); _, lock_path, destination, _, _ = fixture(root)
            destination.mkdir(parents=True); (destination/"prior-resource").write_bytes(b"keep")
            with mock.patch.multiple(installer, ROOT=root, DEST=destination), mock.patch.dict(installer.os.environ, {"GITHUB_TOKEN":"not-a-real-token"}), \
                 mock.patch.object(installer, "github_binary_response", side_effect=RuntimeError("model_download_authorization_failed_http_404")) as transport:
                with self.assertRaises(RuntimeError): installer.install(lock_path)
            self.assertEqual(transport.call_count, 1)
            self.assertEqual(transport.call_args.args[0], "/releases/assets/500")
            self.assertEqual((destination/"prior-resource").read_bytes(), b"keep")

    def test_archive_hash_and_each_internal_file_hash_are_still_required(self):
        for repin_outer in (False, True):
            with self.subTest(repin_outer=repin_outer), self.temporary() as folder:
                root = Path(folder); lock, lock_path, destination, bodies, files = fixture(root)
                name = lock["models"][0]["model"]["files"][0]["relativePath"]
                files["acne"][name] = b"corrupted package bytes"
                corrupted = zipped(files["acne"])
                bodies["/releases/assets/500"] = corrupted
                if repin_outer:
                    lock["models"][0].update(archiveBytes=len(corrupted), archiveSHA256=checksum(corrupted))
                    lock_path.write_text(json.dumps(lock))
                destination.mkdir(parents=True); (destination/"prior-resource").write_bytes(b"keep")
                with mock.patch.multiple(installer, ROOT=root, DEST=destination), mock.patch.dict(installer.os.environ, {"GITHUB_TOKEN":"not-a-real-token"}), \
                     mock.patch.object(installer, "github_binary_response", side_effect=lambda suffix, token: Response(bodies[suffix])):
                    with self.assertRaisesRegex(ValueError, "digest_mismatch|budget_exceeded"):
                        installer.install(lock_path)
                self.assertEqual((destination/"prior-resource").read_bytes(), b"keep")

    def test_destination_must_resolve_to_exact_coreml_directory_before_delete(self):
        with self.temporary() as folder:
            root = Path(folder); _, lock_path, destination, bodies, _ = fixture(root)
            sibling = destination.with_name("OtherResource"); sibling.mkdir(parents=True)
            (sibling/"keep.txt").write_bytes(b"never delete")
            with mock.patch.multiple(installer, ROOT=root, DEST=sibling), mock.patch.dict(installer.os.environ, {"GITHUB_TOKEN":"not-a-real-token"}), \
                 mock.patch.object(installer, "github_binary_response", side_effect=lambda suffix, token: Response(bodies[suffix])):
                with self.assertRaisesRegex(RuntimeError, "unexpected_destination"): installer.install(lock_path)
            self.assertEqual((sibling/"keep.txt").read_bytes(), b"never delete")

    def test_duplicate_entries_and_download_oversize_are_rejected(self):
        output = io.BytesIO()
        with zipfile.ZipFile(output, "w") as archive:
            archive.writestr("same", b"a")
            with self.assertWarns(UserWarning): archive.writestr("same", b"b")
        output.seek(0)
        with zipfile.ZipFile(output) as archive, self.assertRaisesRegex(ValueError, "duplicate"):
            list(installer.safe_files(archive))
        with self.temporary() as folder, mock.patch.object(installer, "github_binary_response", return_value=Response(b"0123456789")):
            path = Path(folder)/"model.zip"
            with self.assertRaisesRegex(ValueError, "byte_budget_exceeded"):
                installer.download_archive("/releases/assets/1", "not-a-real-token", path, 5)
            self.assertLessEqual(path.stat().st_size, 5)

    def test_current_formal_lock_is_still_legacy_and_supported_without_modification(self):
        lock = json.loads(installer.LOCK.read_text(encoding="utf-8"))
        for pin in lock["models"]:
            kind, suffix = installer.archive_source(pin)
            # Once a real reviewed publication receipt upgrades the lock, this test supports both
            # transports, without hard-coding fake Release IDs into production metadata.
            self.assertIn(kind, ("release", "actions"))
            self.assertTrue(suffix.startswith("/releases/assets/" if kind == "release" else "/actions/artifacts/"))


if __name__ == "__main__": unittest.main()
