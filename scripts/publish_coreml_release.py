#!/usr/bin/env python3
"""Persist the three verified original Core ML ZIPs as private release assets.

Run only through the manual publish workflow with its ephemeral GITHUB_TOKEN.
No token is written to a file. API/upload requests never follow redirects with
Authorization; signed storage requests use a separate unauthenticated opener.
No existing release asset is replaced or deleted. All local work is public
model bytes in an ephemeral runner work directory, not user photographs.
"""
from __future__ import annotations

import argparse
import copy
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
LOCK = ROOT/'docs/models/coreml-artifacts.json'
REPOSITORY = '2814152339/MAG-Health-App'
RELEASE_TAG = 'coreml-models-20261112-v1'
API = 'https://api.github.com'
MODELS = {'acne', 'wrinkles', 'skin_type'}
CHUNK = 4 * 1024 * 1024


class PublishError(RuntimeError):
    """Fixed diagnostic codes only; never include URLs, headers or API bodies."""


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs): return None


def sha256(path: Path) -> str:
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(CHUNK), b''): value.update(chunk)
    return value.hexdigest()


def positive_integer(value):
    return isinstance(value, int) and not isinstance(value, bool) and value > 0


def safe_path(name: str) -> bool:
    path = PurePosixPath(name)
    return bool(name) and not path.is_absolute() and '..' not in path.parts and '\\' not in name and ':' not in name


def load_lock(path: Path) -> dict:
    lock = json.loads(path.read_text(encoding='utf-8'))
    records = lock.get('models', [])
    if lock.get('schema') != 1 or len(records) != 3 or {m.get('id') for m in records} != MODELS:
        raise PublishError('invalid_three_model_source_lock')
    for record in records:
        key = record['id']
        model = record.get('model', {})
        if (model.get('id') != key or model.get('package') != f'models/{key}/{key}.mlpackage'
                or not positive_integer(record.get('artifactID')) or not positive_integer(record.get('runID'))
                or not positive_integer(record.get('archiveBytes')) or record['archiveBytes'] > 1024**3
                or not re.fullmatch('[a-f0-9]{64}', record.get('archiveSHA256', ''))):
            raise PublishError('invalid_pinned_model_archive:'+key)
        files = model.get('files', [])
        names = [f.get('relativePath', '') for f in files]
        if not files or len(files) > 30 or len(set(names)) != len(names):
            raise PublishError('invalid_pinned_model_files:'+key)
        for file in files:
            name = file.get('relativePath', '')
            if (not safe_path(name) or not name.startswith(model['package']+'/')
                    or not positive_integer(file.get('bytes'))
                    or not re.fullmatch('[a-f0-9]{64}', file.get('sha256', ''))):
                raise PublishError('invalid_pinned_model_file:'+key)
        validation = record.get('validation', {})
        samples = validation.get('samples', [])
        if (len(samples) != 5 or validation.get('gates', {}).get('allTop1Match') is not True
                or any(s.get('top1Matches') is not True or not 0 <= s.get('maxAbsoluteLogitError', -1) <= .05
                       or not 0 <= s.get('maxAbsoluteProbabilityError', -1) <= .01 for s in samples)):
            raise PublishError('source_lock_not_conversion_verified:'+key)
    return lock


def entries(archive: zipfile.ZipFile, maximum_bytes: int) -> dict:
    infos = archive.infolist()
    if len(infos) > 200 or sum(i.file_size for i in infos) > maximum_bytes:
        raise PublishError('zip_entry_limit_exceeded')
    found = {}
    for info in infos:
        if not safe_path(info.filename) or info.filename in found:
            raise PublishError('zip_unsafe_or_duplicate_path')
        if info.flag_bits & 1 or ((info.external_attr >> 16) & 0o170000) == 0o120000:
            raise PublishError('zip_encryption_or_symlink_rejected')
        if info.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
            raise PublishError('zip_unsupported_compression')
        found[info.filename] = info
    return found


def verify_archive(path: Path, record: dict) -> None:
    key = record['id']
    if path.stat().st_size != record['archiveBytes'] or sha256(path) != record['archiveSHA256']:
        raise PublishError('original_zip_digest_mismatch:'+key)
    with zipfile.ZipFile(path) as archive:
        files = entries(archive, record['archiveBytes']+1024*1024)
        notice_prefix = f'models/{key}/source-notices/'
        allowed = {'model-manifest.json', notice_prefix+'README.md', notice_prefix+'source.json'}
        allowed.update(file['relativePath'] for file in record['model']['files'])
        # Publish only the original known model/notice ZIP, never raw source
        # checkpoints, arbitrary extra attachments, photos, or optimizer state.
        if set(files) != allowed or files['model-manifest.json'].file_size > 256*1024:
            raise PublishError('original_zip_unexpected_payload:'+key)
        manifest = json.loads(archive.read('model-manifest.json'))
        if (manifest.get('schema') != 1 or manifest.get('state') != 'converted_and_coreml_cpu_verified'
                or manifest.get('models') != [record['model']]):
            raise PublishError('original_zip_model_contract_mismatch:'+key)
        for file in record['model']['files']:
            info = files[file['relativePath']]
            if info.file_size != file['bytes']: raise PublishError('package_file_size_mismatch:'+key)
            digest = hashlib.sha256()
            with archive.open(info) as stream:
                for chunk in iter(lambda: stream.read(CHUNK), b''): digest.update(chunk)
            if digest.hexdigest() != file['sha256']: raise PublishError('package_file_digest_mismatch:'+key)


def public_storage_url(url: str) -> bool:
    parsed = urllib.parse.urlsplit(url)
    host = (parsed.hostname or '').lower()
    return (parsed.scheme == 'https' and parsed.port in (None, 443) and not parsed.username and not parsed.password
            and any(host.endswith(suffix) and host != suffix[1:] for suffix in
                    ('.blob.core.windows.net', '.actions.githubusercontent.com', '.githubusercontent.com')))


class GitHub:
    def __init__(self, token: str):
        if not token: raise PublishError('ephemeral_github_token_required')
        self._token = token
        self._api_opener = urllib.request.build_opener(NoRedirect())
        self._public_opener = urllib.request.build_opener(NoRedirect())

    def _headers(self, accept='application/vnd.github+json') -> dict:
        return {'Authorization':'Bearer '+self._token, 'Accept':accept,
                'User-Agent':'Ruyuan-Verified-CoreML-Release', 'X-GitHub-Api-Version':'2022-11-28'}

    def api(self, suffix: str, *, method='GET', body=None, missing_ok=False):
        data = json.dumps(body).encode() if body is not None else None
        headers = self._headers()
        if data is not None: headers['Content-Type'] = 'application/json'
        request = urllib.request.Request(API+'/repos/'+REPOSITORY+suffix, data=data, method=method, headers=headers)
        try:
            with self._api_opener.open(request, timeout=60) as response:
                raw = response.read(4*1024*1024+1)
            if len(raw) > 4*1024*1024: raise PublishError('github_api_response_oversized')
            return json.loads(raw)
        except urllib.error.HTTPError as error:
            if error.code == 404 and missing_ok: return None
            raise PublishError('github_'+method.lower()+'_failed_http_'+str(error.code)) from None
        except (urllib.error.URLError, TimeoutError, OSError):
            raise PublishError('github_'+method.lower()+'_network_failed') from None

    def assert_private(self) -> dict:
        repository = self.api('')
        if repository.get('full_name', '').lower() != REPOSITORY.lower() or repository.get('private') is not True:
            raise PublishError('refusing_nonprivate_or_wrong_repository')
        return repository

    def _unsigned_response(self, url: str):
        # A new Request and opener for every hop: no API Authorization or cookies
        # are forwarded to Azure/release-assets signed storage URLs.
        for _ in range(5):
            if not public_storage_url(url): raise PublishError('unapproved_signed_storage_redirect')
            request = urllib.request.Request(url, headers={'User-Agent':'Ruyuan-Verified-CoreML-Storage'})
            try:
                return self._public_opener.open(request, timeout=180)
            except urllib.error.HTTPError as error:
                if error.code in (301, 302, 303, 307, 308) and error.headers.get('Location'):
                    url = error.headers['Location']
                    continue
                raise PublishError('signed_storage_failed_http_'+str(error.code)) from None
            except (urllib.error.URLError, TimeoutError, OSError):
                raise PublishError('signed_storage_network_failed') from None
        raise PublishError('too_many_signed_storage_redirects')

    def download(self, api_suffix: str, destination: Path, *, expected_bytes: int, expected_sha256=None):
        # Actions ZIP endpoints require the JSON API media type for their 302;
        # only Release binary assets negotiate application/octet-stream.
        if re.fullmatch(r'/actions/artifacts/[1-9][0-9]*/zip', api_suffix):
            accept = 'application/vnd.github+json'
        elif re.fullmatch(r'/releases/assets/[1-9][0-9]*', api_suffix):
            accept = 'application/octet-stream'
        else:
            raise PublishError('unsupported_authenticated_download_endpoint')
        request = urllib.request.Request(API+'/repos/'+REPOSITORY+api_suffix,
                                         headers=self._headers(accept))
        try:
            response = self._api_opener.open(request, timeout=60)
        except urllib.error.HTTPError as error:
            if error.code in (301, 302, 303, 307, 308) and error.headers.get('Location'):
                response = self._unsigned_response(error.headers['Location'])
            else:
                raise PublishError('authenticated_download_failed_http_'+str(error.code)) from None
        except (urllib.error.URLError, TimeoutError, OSError):
            raise PublishError('authenticated_download_network_failed') from None
        destination.parent.mkdir(parents=True, exist_ok=True)
        digest = hashlib.sha256(); count = 0
        try:
            with response, destination.open('wb') as output:
                while chunk := response.read(CHUNK):
                    count += len(chunk)
                    if count > expected_bytes: raise PublishError('download_exceeds_pinned_size')
                    digest.update(chunk); output.write(chunk)
        except (urllib.error.URLError, TimeoutError, OSError):
            raise PublishError('model_download_stream_failed') from None
        if count != expected_bytes: raise PublishError('download_incomplete')
        if expected_sha256 is not None and digest.hexdigest() != expected_sha256:
            raise PublishError('download_sha256_mismatch')

    def assets(self, release_id: int) -> list:
        result = []
        for page in range(1, 21):
            batch = self.api(f'/releases/{release_id}/assets?per_page=100&page={page}')
            result.extend(batch)
            if len(batch) < 100: return result
        raise PublishError('release_asset_pagination_limit')

    def upload(self, release_id: int, path: Path) -> dict:
        # This is GitHub's authenticated upload endpoint, not a signed storage
        # URL. Its exact host/path are constructed, not accepted from a redirect.
        url = f'https://uploads.github.com/repos/{REPOSITORY}/releases/{release_id}/assets?'+urllib.parse.urlencode({'name':path.name})
        headers = self._headers()
        headers.update({'Content-Type':'application/zip', 'Content-Length':str(path.stat().st_size)})
        try:
            with path.open('rb') as stream:
                request = urllib.request.Request(url, data=stream, method='POST', headers=headers)
                with self._api_opener.open(request, timeout=300) as response:
                    raw = response.read(1024*1024+1)
            if len(raw) > 1024*1024: raise PublishError('upload_response_oversized')
            return json.loads(raw)
        except urllib.error.HTTPError as error:
            # Do not automatically delete GitHub's partial/starter asset after
            # an upstream failure: a rerun will report a mismatch for review.
            raise PublishError('release_asset_upload_failed_http_'+str(error.code)) from None
        except (urllib.error.URLError, TimeoutError, OSError):
            raise PublishError('release_asset_upload_network_failed') from None


def verify_asset_metadata(asset: dict, record: dict):
    if (not positive_integer(asset.get('id')) or asset.get('name') != f"Ruyuan-CoreML-{record['id']}.zip"
            or asset.get('state') != 'uploaded' or asset.get('size') != record['archiveBytes']):
        raise PublishError('existing_release_asset_identity_or_size_mismatch:'+record['id'])
    server_digest = asset.get('digest')
    if server_digest is not None and server_digest != 'sha256:'+record['archiveSHA256']:
        raise PublishError('existing_release_asset_digest_mismatch:'+record['id'])


def download_actions_zip(client: GitHub, record: dict, folder: Path, repository_id: int) -> Path:
    key = record['id']; artifact = client.api(f"/actions/artifacts/{record['artifactID']}")
    if (artifact.get('id') != record['artifactID'] or artifact.get('workflow_run', {}).get('id') != record['runID']
            or artifact.get('expired') is not False
            or artifact.get('workflow_run', {}).get('repository_id') != repository_id):
        raise PublishError('source_artifact_expired_or_wrong_provenance:'+key)
    size = artifact.get('size_in_bytes')
    if not positive_integer(size) or size > record['archiveBytes']+16*1024*1024:
        raise PublishError('outer_artifact_size_out_of_bounds:'+key)
    server_digest = artifact.get('digest')
    if server_digest is not None and not re.fullmatch('sha256:[a-f0-9]{64}', server_digest):
        raise PublishError('invalid_outer_artifact_digest:'+key)
    outer = folder/(key+'-actions-artifact.zip')
    client.download(f"/actions/artifacts/{record['artifactID']}/zip", outer,
                    expected_bytes=size, expected_sha256=server_digest[7:] if server_digest else None)
    inner = folder/f'Ruyuan-CoreML-{key}.zip'
    with zipfile.ZipFile(outer) as archive:
        members = entries(archive, record['archiveBytes']+16*1024*1024)
        member = members.get(inner.name)
        if member is None or member.file_size != record['archiveBytes'] or member.is_dir():
            raise PublishError('pinned_original_zip_missing:'+key)
        with archive.open(member) as source, inner.open('wb') as output:
            count = 0
            while chunk := source.read(CHUNK):
                count += len(chunk)
                if count > record['archiveBytes']: raise PublishError('nested_original_zip_oversized:'+key)
                output.write(chunk)
    verify_archive(inner, record)
    return inner


def publish(client: GitHub, lock: dict, source_lock_hash: str, work: Path) -> dict:
    repository = client.assert_private()
    release = client.api('/releases/tags/'+RELEASE_TAG, missing_ok=True)
    if release is not None and (release.get('tag_name') != RELEASE_TAG or not positive_integer(release.get('id'))):
        raise PublishError('existing_release_tag_mismatch')
    existing = client.assets(release['id']) if release else []
    found = {}; local = {}; source_states = {}
    # First verify existing assets and fetch any missing pinned originals. Thus
    # a complete release rerun is independent of Actions artifact retention.
    for record in lock['models']:
        key = record['id']; name = f'Ruyuan-CoreML-{key}.zip'
        matches = [asset for asset in existing if asset.get('name') == name]
        if len(matches) > 1: raise PublishError('duplicate_existing_release_asset:'+key)
        if matches:
            asset = matches[0]; verify_asset_metadata(asset, record)
            path = work/name
            client.download(f"/releases/assets/{asset['id']}", path, expected_bytes=record['archiveBytes'],
                            expected_sha256=record['archiveSHA256'])
            verify_archive(path, record); found[key] = asset; local[key] = path
            source_states[key] = 'existing_release_asset_fully_downloaded_and_verified'
        else:
            if release and release.get('immutable'): raise PublishError('immutable_release_missing_model:'+key)
            local[key] = download_actions_zip(client, record, work, repository['id'])
            source_states[key] = 'hash_pinned_original_actions_zip'
    if release is None:
        # Pin an already-present default-branch commit. No workflow permission
        # escalation is requested to mint a tag at a workflow-only branch SHA.
        branch = urllib.parse.quote(repository['default_branch'], safe='')
        target = client.api('/commits/'+branch)['sha']
        if not re.fullmatch('[a-f0-9]{40}', target): raise PublishError('invalid_default_branch_commit')
        client.assert_private()
        release = client.api('/releases', method='POST', body={
            'tag_name':RELEASE_TAG, 'target_commitish':target,
            'name':'Verified Core ML Models 2026-11-12 v1',
            'body':'Private verified Core ML assets. Original internal ZIPs preserved byte-for-byte.\nSource lock SHA256: '+source_lock_hash,
            'draft':False, 'prerelease':True, 'make_latest':'false', 'generate_release_notes':False})
        if release.get('tag_name') != RELEASE_TAG or not positive_integer(release.get('id')):
            raise PublishError('created_release_identity_mismatch')
    for record in lock['models']:
        key = record['id']
        if key in found: continue
        client.assert_private()
        # Re-list just before upload to handle another publisher without ever
        # overwriting/deleting its same-name asset.
        matches = [a for a in client.assets(release['id']) if a.get('name') == local[key].name]
        if len(matches) > 1: raise PublishError('duplicate_release_asset_before_upload:'+key)
        asset = matches[0] if matches else client.upload(release['id'], local[key])
        verify_asset_metadata(asset, record)
        delivered = work/(key+'-verified-release-download.zip')
        client.download(f"/releases/assets/{asset['id']}", delivered,
                        expected_bytes=record['archiveBytes'], expected_sha256=record['archiveSHA256'])
        verify_archive(delivered, record); found[key] = asset
    client.assert_private()
    result = copy.deepcopy(lock)
    result['publication'] = {'state':'private_release_assets_fully_verified', 'repository':REPOSITORY,
                             'tag':RELEASE_TAG, 'releaseID':release['id'], 'sourceLockSHA256':source_lock_hash,
                             'verifiedAt':datetime.now(timezone.utc).isoformat(), 'repositoryPrivateAtVerification':True}
    for record in result['models']:
        asset = found[record['id']]
        record.update({'releaseAssetID':asset['id'], 'releaseID':release['id'], 'releaseTag':RELEASE_TAG,
                       'source':{'type':'githubRelease', 'repository':REPOSITORY, 'tag':RELEASE_TAG,
                                 'releaseID':release['id'], 'assetID':asset['id'], 'assetName':asset['name'],
                                 'apiURL':f"{API}/repos/{REPOSITORY}/releases/assets/{asset['id']}"}})
    return {'lock':result, 'receipt':{'state':'private_release_assets_fully_verified', 'releaseID':release['id'],
            'tag':RELEASE_TAG, 'sourceLockSHA256':source_lock_hash,
            'models':[{'id':r['id'], 'releaseAssetID':found[r['id']]['id'], 'sha256':r['archiveSHA256'],
                       'bytes':r['archiveBytes'], 'source':source_states[r['id']]} for r in lock['models']]}}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--lock', type=Path, default=LOCK)
    parser.add_argument('--work', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if (args.output/'coreml-release-lock.json').resolve() == args.lock.resolve():
        parser.error('Output must be a separate candidate lock, not the formal source lock.')
    args.output.mkdir(parents=True, exist_ok=True); args.work.mkdir(parents=True, exist_ok=True)
    try:
        if os.environ.get('GITHUB_REPOSITORY') != REPOSITORY or os.environ.get('GITHUB_ACTIONS') != 'true':
            raise PublishError('manual_private_repository_workflow_required')
        result = publish(GitHub(os.environ.get('GITHUB_TOKEN', '')), load_lock(args.lock), sha256(args.lock), args.work)
        (args.output/'coreml-release-lock.json').write_text(json.dumps(result['lock'], indent=2)+'\n', encoding='utf-8')
        receipt = result['receipt']
        (args.output/'publish-receipt.json').write_text(json.dumps(receipt, indent=2)+'\n', encoding='utf-8')
        print(json.dumps(receipt, separators=(',',':')), flush=True)
        return 0
    except Exception as error:
        # Deliberately do not print urllib exceptions, request headers, response
        # bodies or tracebacks that could contain a token or signed URL.
        receipt = {'state':'failed', 'errorType':type(error).__name__,
                   'error':str(error) if isinstance(error, PublishError) else 'unexpected_error_no_secret_details_logged'}
        (args.output/'publish-receipt.json').write_text(json.dumps(receipt, indent=2)+'\n', encoding='utf-8')
        print(json.dumps(receipt, separators=(',',':')), flush=True)
        return 1


if __name__ == '__main__': sys.exit(main())
