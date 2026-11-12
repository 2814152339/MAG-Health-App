"""Offline publication safety/idempotence tests; no real GitHub writes."""
import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
import urllib.error
import zipfile

SCRIPT = Path(__file__).resolve().parents[1]/'publish_coreml_release.py'
SPEC = importlib.util.spec_from_file_location('publisher', SCRIPT)
publisher = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(publisher)


def checksum(data): return hashlib.sha256(data).hexdigest()


def zipped(files):
    output = io.BytesIO()
    with zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_STORED) as archive:
        for name, value in files.items(): archive.writestr(name, value)
    return output.getvalue()


def fixture():
    records = []; sources = {}
    for index, key in enumerate(('acne', 'wrinkles', 'skin_type')):
        name = f'models/{key}/{key}.mlpackage'
        package = {name+'/Data/com.apple.CoreML/model.mlmodel':b'compiled-description',
                   name+'/Data/com.apple.CoreML/weights/weight.bin':b'public-weight-bytes',
                   name+'/Manifest.json':b'{}'}
        model = {'id':key, 'package':name, 'files':[{'relativePath':n,'bytes':len(v),'sha256':checksum(v)} for n,v in package.items()]}
        manifest = {'schema':1,'state':'converted_and_coreml_cpu_verified','models':[model]}
        inner_files = {**package, 'model-manifest.json':json.dumps(manifest).encode(),
                       f'models/{key}/source-notices/README.md':b'author notice',
                       f'models/{key}/source-notices/source.json':b'{}'}
        inner = zipped(inner_files)
        record = {'id':key,'artifactID':100+index,'runID':200+index,'archiveBytes':len(inner),
                  'archiveSHA256':checksum(inner),'model':model,
                  'validation':{'gates':{'allTop1Match':True},'samples':[{'top1Matches':True,
                    'maxAbsoluteLogitError':.001,'maxAbsoluteProbabilityError':.0001} for _ in range(5)]}}
        records.append(record)
        sources[record['artifactID']] = {'inner':inner, 'outer':zipped({f'Ruyuan-CoreML-{key}.zip':inner})}
    return {'schema':1,'models':records}, sources


class FakeGitHub:
    def __init__(self, lock, sources):
        self.lock = lock; self.sources = sources; self.release = None
        self.uploaded = {}; self.stored = {}; self.upload_calls = 0; self.create_calls = 0; self.actions_calls = 0

    def assert_private(self):
        return {'id':42,'private':True,'full_name':publisher.REPOSITORY,'default_branch':'main'}

    def api(self, suffix, *, method='GET', body=None, missing_ok=False):
        if suffix.startswith('/releases/tags/'): return self.release
        if suffix == '/commits/main': return {'sha':'a'*40}
        if suffix == '/releases' and method == 'POST':
            self.create_calls += 1; self.release = {'id':7,'tag_name':publisher.RELEASE_TAG}; return self.release
        if suffix.startswith('/actions/artifacts/'):
            self.actions_calls += 1; aid = int(suffix.rsplit('/',1)[1]); record = next(r for r in self.lock['models'] if r['artifactID']==aid)
            outer = self.sources[aid]['outer']
            return {'id':aid,'expired':False,'size_in_bytes':len(outer),'digest':'sha256:'+checksum(outer),
                    'workflow_run':{'id':record['runID'],'repository_id':42}}
        raise AssertionError('Unexpected mocked API endpoint')

    def assets(self, release_id): return list(self.uploaded.values())

    def download(self, suffix, destination, *, expected_bytes, expected_sha256=None):
        if suffix.startswith('/actions/artifacts/'):
            data = self.sources[int(suffix.split('/')[3])]['outer']
        else: data = self.stored[int(suffix.rsplit('/',1)[1])]
        assert len(data) == expected_bytes
        if expected_sha256 is not None: assert checksum(data) == expected_sha256
        destination.write_bytes(data)

    def upload(self, release_id, path):
        self.upload_calls += 1; asset_id = 500+self.upload_calls; data = path.read_bytes()
        asset = {'id':asset_id,'name':path.name,'size':len(data),'state':'uploaded','digest':'sha256:'+checksum(data)}
        self.uploaded[asset_id] = asset; self.stored[asset_id] = data
        return asset


class Response(io.BytesIO):
    def __enter__(self): return self
    def __exit__(self, *args): self.close()


class PublicationTests(unittest.TestCase):
    def test_actual_current_lock_passes_offline_schema_and_validation_gate(self):
        lock = publisher.load_lock(publisher.LOCK)
        self.assertEqual({r['id'] for r in lock['models']}, publisher.MODELS)

    def test_first_publish_then_repeat_uses_verified_release_not_expired_actions(self):
        lock, sources = fixture(); client = FakeGitHub(lock, sources); original = copy.deepcopy(lock)
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            first = publisher.publish(client, lock, 'c'*64, work)
            self.assertEqual(client.upload_calls, 3); self.assertEqual(client.create_calls, 1)
            self.assertEqual(lock, original)
            self.assertEqual({r['source']['type'] for r in first['lock']['models']}, {'githubRelease'})
            client.sources = {}  # Simulate every original Actions artifact expiring.
            second = publisher.publish(client, lock, 'c'*64, work)
            self.assertEqual(client.upload_calls, 3); self.assertEqual(client.actions_calls, 3)
            self.assertEqual([r['releaseAssetID'] for r in first['lock']['models']], [r['releaseAssetID'] for r in second['lock']['models']])

    def test_existing_different_hash_asset_is_never_replaced(self):
        lock, sources = fixture(); client = FakeGitHub(lock, sources)
        client.release = {'id':7,'tag_name':publisher.RELEASE_TAG}
        client.uploaded[900] = {'id':900,'name':'Ruyuan-CoreML-acne.zip','state':'uploaded',
                                'size':lock['models'][0]['archiveBytes'],'digest':'sha256:'+'0'*64}
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(publisher.PublishError, 'digest_mismatch'):
                publisher.publish(client, lock, 'c'*64, Path(directory))
        self.assertEqual(client.upload_calls, 0); self.assertEqual(client.create_calls, 0)

    def test_corrupted_original_stops_before_release_creation(self):
        lock, sources = fixture(); client = FakeGitHub(lock, sources)
        sources[100]['outer'] = zipped({'Ruyuan-CoreML-acne.zip':sources[100]['inner'][:-1]+b'!'} )
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(publisher.PublishError, 'digest_mismatch'):
                publisher.publish(client, lock, 'c'*64, Path(directory))
        self.assertEqual(client.create_calls, 0); self.assertEqual(client.upload_calls, 0)

    def test_zip_rejects_traversal_duplicate_and_photo_payload(self):
        with zipfile.ZipFile(io.BytesIO(zipped({'../photo.jpg':b'not a model'}))) as archive:
            with self.assertRaisesRegex(publisher.PublishError, 'unsafe'):
                publisher.entries(archive, 100)
        lock, sources = fixture(); record = lock['models'][0]
        with zipfile.ZipFile(io.BytesIO(sources[100]['inner'])) as archive:
            files = {n:archive.read(n) for n in archive.namelist()}
        files['private-photo.jpg'] = b'rejected even if checksum gets repinned'
        data = zipped(files); record['archiveBytes'] = len(data); record['archiveSHA256'] = checksum(data)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'candidate.zip'; path.write_bytes(data)
            with self.assertRaisesRegex(publisher.PublishError, 'unexpected_payload'):
                publisher.verify_archive(path, record)

    def test_signed_redirect_never_receives_api_authorization(self):
        api_requests = []; unsigned_requests = []; data = b'abc'
        class APITransport:
            def open(self, request, **kwargs):
                api_requests.append(request)
                raise urllib.error.HTTPError(request.full_url, 302, 'redirect',
                                              {'Location':'https://production.blob.core.windows.net/model?secret=unit-test'}, None)
        class StorageTransport:
            def open(self, request, **kwargs):
                unsigned_requests.append(request); return Response(data)
        client = publisher.GitHub('not-a-real-token'); client._api_opener = APITransport(); client._public_opener = StorageTransport()
        with tempfile.TemporaryDirectory() as directory:
            client.download('/actions/artifacts/1/zip', Path(directory)/'artifact.zip', expected_bytes=3, expected_sha256=checksum(data))
        self.assertIn('Authorization', dict(api_requests[0].header_items()))
        self.assertEqual(api_requests[0].get_header('Accept'), 'application/vnd.github+json')
        self.assertNotIn('Authorization', dict(unsigned_requests[0].header_items()))
        self.assertFalse(publisher.public_storage_url('https://api.github.com/not-storage'))
        self.assertFalse(publisher.public_storage_url('http://production.blob.core.windows.net/model'))
        self.assertFalse(publisher.public_storage_url('https://evil.test/@production.blob.core.windows.net/model'))

    def test_release_binary_media_type_and_unknown_endpoint_rejected(self):
        requests = []
        class Transport:
            def open(self, request, **kwargs):
                requests.append(request)
                return Response(b'abc')
        client = publisher.GitHub('not-a-real-token'); client._api_opener = Transport()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'model.zip'
            client.download('/releases/assets/7', path, expected_bytes=3, expected_sha256=checksum(b'abc'))
            self.assertEqual(requests[0].get_header('Accept'), 'application/octet-stream')
            with self.assertRaisesRegex(publisher.PublishError, 'unsupported_authenticated_download_endpoint'):
                client.download('/arbitrary', path, expected_bytes=3)
            self.assertEqual(len(requests), 1)

    def test_upload_stream_has_exact_length_and_only_github_upload_host(self):
        requests = []
        class UploadTransport:
            def open(self, request, **kwargs):
                requests.append((request, request.data.read()))
                return Response(json.dumps({'id':1,'state':'uploaded'}).encode())
        client = publisher.GitHub('not-a-real-token'); client._api_opener = UploadTransport()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'Ruyuan-CoreML-acne.zip'; path.write_bytes(b'abc')
            client.upload(7, path)
        request, body = requests[0]
        self.assertEqual(body, b'abc'); self.assertEqual(request.get_header('Content-length'), '3')
        self.assertTrue(request.full_url.startswith('https://uploads.github.com/repos/'+publisher.REPOSITORY+'/'))


if __name__ == '__main__': unittest.main()
