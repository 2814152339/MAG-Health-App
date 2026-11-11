from __future__ import annotations

import io
import json
import threading
import time
import uuid
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from fastapi import HTTPException
from PIL import Image

from ruyuan.app import create_app
from ruyuan.config import Settings

TOKEN = "a-private-test-token-only-" + "a" * 32
OTHER = "another-private-test-token-" + "b" * 32
AUTH = {"Authorization": f"Bearer {TOKEN}"}
DEFAULT_HEADERS = {**AUTH, "Idempotency-Key": "default-test-upload-key"}


def stub_analyzer(path, settings, progress):
    """Deterministic injection ONLY in tests; production factory has no stub flag."""
    progress("quality_checking", 0.2)
    progress("geometry", 0.4)
    progress("skin_models", 0.7)
    with Image.open(path) as image:
        width, height = image.size
    return {
        "id": "", "createdAt": "2026-11-11T12:00:00.000Z", "origin": "server", "status": "partial",
        "imageFileName": path.name, "imageWidth": width, "imageHeight": height,
        "geometry": [], "skin": [{"dimension": d, "score": None, "status": "test-only", "items": []}
                                    for d in ["waterOil", "tone", "sensitivity", "smoothness", "aging"]],
        "landmarks": [], "overlays": [], "quality": [], "modelVersion": "TEST-ONLY-STUB", "summary": "test fixture",
    }


def jpeg(width=300, height=400):
    output = io.BytesIO()
    Image.new("RGB", (width, height), (180, 140, 120)).save(output, "JPEG")
    return output.getvalue()


@pytest.fixture
def settings(tmp_path):
    return Settings(TOKEN, tmp_path / "private")


@pytest.fixture
def client(settings):
    app = create_app(settings, analyzer=stub_analyzer)
    with TestClient(app, headers=DEFAULT_HEADERS) as client:
        yield client


def upload(client, content=None, key=None):
    result = client.post("/v1/uploads", headers={"Idempotency-Key": key or uuid.uuid4().hex}, files={"file": ("../../secret.jpg", content or jpeg(), "image/jpeg")})
    assert result.status_code == 201, result.text
    return result.json()["assetId"]


def consent(client):
    response = client.post("/v1/consents", json={"purpose": "skin_appearance_analysis", "version": "1.0"})
    assert response.status_code == 201
    return response.json()["consentId"]


def begin(client, asset_id=None, key="test-key-123"):
    payload = {"assetId": asset_id or upload(client, key=key), "consentId": consent(client), "idempotencyKey": key}
    response = client.post("/v1/analyses", json=payload)
    assert response.status_code == 202, response.text
    return response.json(), payload


def finished(client, job_id):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        response = client.get(f"/v1/analyses/{job_id}")
        assert response.status_code == 200
        if response.json()["status"] in {"completed", "failed"}:
            return response.json()
        time.sleep(0.01)
    pytest.fail("worker did not finish")


def test_auth_and_health(settings):
    with TestClient(create_app(settings)) as client:
        assert client.get("/healthz").json()["status"] == "ok"
        assert client.get("/v1/analyses/" + "0" * 32).status_code == 401
        assert client.post("/v1/uploads", headers={"Authorization": f"Bearer {OTHER}"}, files={"file": ("x.jpg", jpeg())}).status_code == 401
        assert client.get("/v1/assets/" + "0" * 32, headers={b"Authorization": b"Bearer \xf1"}).status_code == 401


def test_token_required(tmp_path):
    with pytest.raises(ValueError, match="at least 32"):
        Settings("", tmp_path)
    with pytest.raises(ValueError):
        Settings("changeme", tmp_path)


def test_upload_normalized_private_and_path_safe(client, settings):
    asset_id = upload(client)
    image = client.get(f"/v1/assets/{asset_id}")
    assert image.status_code == 200
    assert image.headers["content-type"] == "image/jpeg"
    assert image.headers["cache-control"] == "no-store"
    assert (settings.data_dir / "assets" / f"{asset_id}.jpg").is_file()
    assert not (settings.data_dir.parent / "secret.jpg").exists()
    assert client.get("/v1/assets/not-an-id").status_code == 404
    assert client.get("/private-data/ledger.sqlite3").status_code == 404


@pytest.mark.parametrize("data,expected", [(b"not an image", 422), (jpeg(100, 100), 422), (jpeg()[:30], 422)])
def test_invalid_files(client, data, expected):
    assert client.post("/v1/uploads", files={"file": ("p.jpg", data)}).status_code == expected


def test_limits_and_unsupported(settings):
    limited = Settings(TOKEN, settings.data_dir, max_upload_bytes=2048, max_pixels=100_000)
    with TestClient(create_app(limited), headers=DEFAULT_HEADERS) as client:
        assert client.post("/v1/uploads", files={"file": ("big.jpg", b"x" * 2049)}).status_code == 413
        # Tiny compressed PNG with too many pixels is rejected before full decode.
        output = io.BytesIO()
        Image.new("RGB", (400, 400)).save(output, "PNG")
        assert client.post("/v1/uploads", files={"file": ("big.png", output.getvalue())}).status_code == 413
        output = io.BytesIO()
        Image.new("RGB", (300, 300)).save(output, "GIF")
        assert client.post("/v1/uploads", files={"file": ("image.gif", output.getvalue())}).status_code == 415


def test_streaming_total_body_limit(settings):
    limited = Settings(TOKEN, settings.data_dir, max_upload_bytes=512)
    with TestClient(create_app(limited), headers=DEFAULT_HEADERS) as client:
        response = client.post("/v1/uploads", content=iter([b"x" * 400_000]), headers={"Content-Type": "multipart/form-data; boundary=x"})
        assert response.status_code == 413


def test_idempotency_and_report_contract(client):
    job, payload = begin(client)
    again = client.post("/v1/analyses", json=payload)
    assert again.status_code == 202 and again.json()["id"] == job["id"]
    changed = {**payload, "assetId": upload(client)}
    assert client.post("/v1/analyses", json=changed).status_code == 409
    result = finished(client, job["id"])
    assert result["status"] == "completed" and result["error"] is None
    report = client.get(f"/v1/reports/{result['reportId']}")
    assert report.status_code == 200
    body = report.json()
    assert set(body) == {"id", "createdAt", "origin", "status", "imageFileName", "imageWidth", "imageHeight", "geometry", "skin", "landmarks", "overlays", "quality", "modelVersion", "summary"}
    assert body["createdAt"].endswith("Z") and all(m["score"] is None for m in body["skin"])
    assert body["imageWidth"] == 300


def test_unknown_owner_field_and_consent_enforced(client):
    asset_id = upload(client)
    body = {"assetId": asset_id, "consentId": "0" * 32, "idempotencyKey": "test-key-no-consent"}
    assert client.post("/v1/analyses", json=body).status_code == 422
    assert client.post("/v1/analyses", json={**body, "owner": "pretend-owner"}).status_code == 422
    assert client.post("/v1/consents", json={"purpose": "skin_appearance_analysis", "version": "old"}).status_code == 422


def test_real_analyzer_fails_without_model(settings):
    with TestClient(create_app(settings), headers=AUTH) as client:
        job, _ = begin(client)
        result = finished(client, job["id"])
        assert result["status"] == "failed"
        assert result["error"] == "model_not_configured"
        assert result["reportId"] is None


def test_persistent_job_and_restart_resume(settings):
    first = create_app(settings, analyzer=stub_analyzer, run_workers=False)
    with TestClient(first, headers=AUTH) as client:
        job, payload = begin(client)
        assert client.get(f"/v1/analyses/{job['id']}").json()["status"] == "queued"
        # Simulate process death during native inference, not clean cancellation.
        with first.state.service.store.transaction() as db:
            db.execute("UPDATE jobs SET status='running',attempt=1 WHERE id=?", (job["id"],))
    with TestClient(create_app(settings, analyzer=stub_analyzer), headers=AUTH) as client:
        result = finished(client, job["id"])
        assert result["status"] == "completed"
        assert client.post("/v1/analyses", json=payload).json()["id"] == job["id"]


def test_restart_retry_cap(settings):
    app = create_app(settings, run_workers=False)
    with TestClient(app, headers=AUTH) as client:
        job, _ = begin(client)
        with app.state.service.store.transaction() as db:
            db.execute("UPDATE jobs SET status='running',attempt=3 WHERE id=?", (job["id"],))
    with TestClient(create_app(settings), headers=AUTH) as client:
        result = client.get(f"/v1/analyses/{job['id']}").json()
        assert result["status"] == "failed" and result["error"] == "restart_limit_reached"


def test_rotated_token_cannot_read_old_owner(settings):
    with TestClient(create_app(settings, analyzer=stub_analyzer), headers=AUTH) as client:
        job, payload = begin(client)
        report_id = finished(client, job["id"])["reportId"]
    rotated = Settings(OTHER, settings.data_dir)
    with TestClient(create_app(rotated), headers={"Authorization": f"Bearer {OTHER}"}) as client:
        for route in [f"analyses/{job['id']}", f"reports/{report_id}", f"assets/{payload['assetId']}"]:
            assert client.get("/v1/" + route).status_code == 404
            assert client.delete("/v1/" + route).status_code == 204
        assert client.post("/v1/analyses", json=payload).status_code == 404
    # The cross-owner deletes must not destroy old records.
    with TestClient(create_app(settings), headers=AUTH) as client:
        assert client.get(f"/v1/reports/{report_id}").status_code == 200


@pytest.mark.parametrize("resource", ["analyses", "reports"])
def test_delete_completed_removes_asset_report_and_is_idempotent(client, settings, resource):
    job, payload = begin(client)
    result = finished(client, job["id"])
    resource_id = job["id"] if resource == "analyses" else result["reportId"]
    assert client.delete(f"/v1/{resource}/{resource_id}").status_code == 204
    assert client.delete(f"/v1/{resource}/{resource_id}").status_code == 204
    assert client.get(f"/v1/analyses/{job['id']}").status_code == 404
    assert client.get(f"/v1/reports/{result['reportId']}").status_code == 404
    assert client.get(f"/v1/assets/{payload['assetId']}").status_code == 404
    assert not (settings.data_dir / "assets" / f"{payload['assetId']}.jpg").exists()
    assert client.post("/v1/analyses", json=payload).status_code == 410


def test_upload_before_job_cleanup(client):
    asset_id = upload(client)
    assert client.delete(f"/v1/assets/{asset_id}").status_code == 204
    assert client.delete(f"/v1/assets/{asset_id}").status_code == 204
    assert client.get(f"/v1/assets/{asset_id}").status_code == 404


def test_delete_running_discards_late_result(settings):
    entered, finish = threading.Event(), threading.Event()

    def slow(path, settings, progress):
        result = stub_analyzer(path, settings, progress)
        entered.set()
        assert finish.wait(5)
        return result

    with TestClient(create_app(settings, analyzer=slow), headers=AUTH) as client:
        job, payload = begin(client)
        assert entered.wait(5)
        assert client.delete(f"/v1/assets/{payload['assetId']}").status_code == 409
        assert client.delete(f"/v1/analyses/{job['id']}").status_code == 204
        finish.set()
    with TestClient(create_app(settings), headers=AUTH) as client:
        assert client.get(f"/v1/analyses/{job['id']}").status_code == 404
        with client.app.state.service.store.transaction() as db:
            assert db.execute("SELECT count(*) FROM reports").fetchone()[0] == 0


def test_upload_key_required(client):
    key = client.headers.pop("Idempotency-Key")
    try:
        assert client.post("/v1/uploads", files={"file": ("p.jpg", jpeg())}).status_code == 422
    finally:
        client.headers["Idempotency-Key"] = key


def test_cancel_before_upload_and_replay(client):
    key = "cancel-before-upload-key"
    assert client.delete(f"/v1/operations/{key}").status_code == 204
    assert client.delete(f"/v1/operations/{key}").status_code == 204
    assert client.post("/v1/uploads", headers={"Idempotency-Key": key}, files={"file": ("p.jpg", jpeg())}).status_code == 410
    assert client.post("/v1/analyses", json={"assetId": "0" * 32, "consentId": "0" * 32, "idempotencyKey": key}).status_code == 410


def test_upload_response_loss_replay_same_receipt(client, settings):
    key = "response-lost-upload-key"
    first = upload(client, key=key)
    assert upload(client, key=key) == first
    assert len(list((settings.data_dir / "assets").glob("*.jpg"))) == 1
    changed = client.post("/v1/uploads", headers={"Idempotency-Key": key}, files={"file": ("p.jpg", jpeg(301, 400))})
    assert changed.status_code == 409


def test_cancel_upload_before_create_removes_unknown_receipt(client, settings):
    key = "cancel-before-create-key"
    asset_id = upload(client, key=key)
    consent_id = consent(client)
    assert client.delete(f"/v1/operations/{key}").status_code == 204
    assert client.get(f"/v1/assets/{asset_id}").status_code == 404
    assert not (settings.data_dir / "assets" / f"{asset_id}.jpg").exists()
    assert client.post("/v1/analyses", json={"assetId": asset_id, "consentId": consent_id, "idempotencyKey": key}).status_code == 410


def test_cancel_operation_after_completed_removes_all(client):
    key = "cancel-completed-operation"
    job, payload = begin(client, key=key)
    result = finished(client, job["id"])
    assert client.delete(f"/v1/operations/{key}").status_code == 204
    assert client.get(f"/v1/assets/{payload['assetId']}").status_code == 404
    assert client.get(f"/v1/analyses/{job['id']}").status_code == 404
    assert client.get(f"/v1/reports/{result['reportId']}").status_code == 404
    assert client.post("/v1/analyses", json=payload).status_code == 410


def test_operation_tombstone_persists_restart(settings):
    key = "cancel-persistent-operation"
    with TestClient(create_app(settings), headers=AUTH) as client:
        assert client.delete(f"/v1/operations/{key}").status_code == 204
    with TestClient(create_app(settings), headers=AUTH) as client:
        assert client.post("/v1/uploads", headers={"Idempotency-Key": key}, files={"file": ("p.jpg", jpeg())}).status_code == 410


def test_cancel_during_upload_decode_prevents_late_commit(settings, monkeypatch):
    from ruyuan import app as app_module

    app = create_app(settings, run_workers=False)
    service = app.state.service
    entered, released = threading.Event(), threading.Event()
    original = app_module.ImageOps.exif_transpose
    key = "cancel-inflight-upload"
    outcome = []

    def paused(image):
        entered.set()
        assert released.wait(5)
        return original(image)

    monkeypatch.setattr(app_module.ImageOps, "exif_transpose", paused)

    def receive_upload():
        try:
            service.upload(jpeg(), key)
            outcome.append("unexpected-success")
        except HTTPException as error:
            outcome.append(error.status_code)

    with TestClient(app, headers=AUTH) as client:
        worker = threading.Thread(target=receive_upload)
        worker.start()
        assert entered.wait(5)
        assert client.delete(f"/v1/operations/{key}").status_code == 204
        released.set()
        worker.join(5)
        assert not worker.is_alive()
        assert outcome == [410]
        assert not list(service.store.assets.glob("*.jpg"))


def test_operation_cross_owner_and_auth(settings):
    key = "shared-key-not-owner"
    with TestClient(create_app(settings, analyzer=stub_analyzer), headers=AUTH) as client:
        job, payload = begin(client, key=key)
        finished(client, job["id"])
    with TestClient(create_app(Settings(OTHER, settings.data_dir))) as client:
        assert client.delete(f"/v1/operations/{key}").status_code == 401
        assert client.delete(f"/v1/operations/{key}", headers={"Authorization": f"Bearer {OTHER}"}).status_code == 204
    with TestClient(create_app(settings), headers=AUTH) as client:
        assert client.get(f"/v1/assets/{payload['assetId']}").status_code == 200
        assert client.get(f"/v1/analyses/{job['id']}").status_code == 200


def test_upload_strips_exif_and_corrects_orientation(client):
    output = io.BytesIO()
    exif = Image.Exif()
    exif[274] = 6
    exif[270] = "private photo metadata"
    Image.new("RGB", (300, 400)).save(output, "JPEG", exif=exif)
    asset_id = upload(client, content=output.getvalue())
    with Image.open(io.BytesIO(client.get(f"/v1/assets/{asset_id}").content)) as image:
        assert image.size == (400, 300)
        assert not image.getexif()
