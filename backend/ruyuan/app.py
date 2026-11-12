from __future__ import annotations

import io
import hashlib
import json
import re
import secrets
import threading
import uuid
import warnings
from concurrent.futures import ThreadPoolExecutor
from contextlib import asynccontextmanager
from typing import Callable

from fastapi import Depends, FastAPI, HTTPException, Request, Response
from fastapi.responses import JSONResponse
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from PIL import Image, ImageOps, UnidentifiedImageError
from starlette.concurrency import run_in_threadpool
from starlette.datastructures import UploadFile

from .analyzer import AnalysisFailure, Cancelled, analyze, utc_now
from .config import Settings
from .lease import ProcessLease
from .schemas import AnalysisReport, AnalysisRequest, ConsentRequest
from .storage import Store

ID = re.compile(r"^[0-9a-f]{32}$")
OPERATION_KEY = re.compile(r"^[A-Za-z0-9_.:-]{8,128}$")
TERMINAL = {"completed", "failed", "cancelled"}


def new_id() -> str:
    return uuid.uuid4().hex


class UploadTooLarge(Exception):
    pass


class BodyLimitMiddleware:
    """Limit streaming bodies BEFORE multipart parsing / temporary-file spooling."""

    def __init__(self, app, max_bytes: int):
        self.app, self.max_bytes = app, max_bytes

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        limit = self.max_bytes if scope["path"] == "/v1/uploads" else 64 * 1024
        headers = dict(scope["headers"])
        try:
            declared = int(headers.get(b"content-length", b"0"))
        except ValueError:
            declared = 0
        if declared > limit:
            return await JSONResponse({"detail": "upload_too_large"}, 413)(scope, receive, send)
        consumed = 0

        async def bounded_receive():
            nonlocal consumed
            message = await receive()
            consumed += len(message.get("body", b""))
            if consumed > limit:
                raise UploadTooLarge()
            return message

        try:
            await self.app(scope, bounded_receive, send)
        except UploadTooLarge:
            await JSONResponse({"detail": "upload_too_large"}, 413)(scope, receive, send)


class Service:
    def __init__(self, settings: Settings, analyzer: Callable = analyze, *, run_workers: bool = True):
        self.settings, self.analyzer = settings, analyzer
        self.store = Store(settings.data_dir)
        self.owner = settings.owner
        self.pool = ThreadPoolExecutor(max_workers=settings.workers, thread_name_prefix="ruyuan") if run_workers else None
        self.stopping = threading.Event()
        self.lease = ProcessLease(self.store.root / "process.lock")

    def start(self) -> None:
        self.lease.acquire()
        # A single OS process owns the ledger. Resume interrupted work at most 3
        # times. A finished/failed task is NEVER silently regenerated.
        with self.store.transaction() as db:
            db.execute("""UPDATE jobs SET status='failed', error='restart_limit_reached', updated_at=?
                          WHERE owner=? AND deleted=0 AND status IN ('queued','running') AND attempt>=3""",
                       (utc_now(), self.owner))
            db.execute("""UPDATE jobs SET status='queued', stage='preparing', progress=0, updated_at=?
                          WHERE owner=? AND deleted=0 AND status IN ('queued','running') AND attempt<3""",
                       (utc_now(), self.owner))
            pending = [r["id"] for r in db.execute("SELECT id FROM jobs WHERE owner=? AND status='queued' AND deleted=0", (self.owner,))]
            # An interrupted upload may leave an uncommitted file. Files are only
            # removed inside this private, resolved assets directory.
            known = {r["id"] for r in db.execute("SELECT id FROM assets")}
            for path in self.store.assets.iterdir():
                if path.is_file() and path.suffix in {".jpg", ".tmp"} and path.stem not in known:
                    path.unlink(missing_ok=True)
        for job_id in pending:
            self.submit(job_id)

    def close(self) -> None:
        self.stopping.set()
        if self.pool:
            # Native inference cannot be forcibly interrupted safely. Results are
            # discarded, and interrupted ledger jobs remain resumable.
            self.pool.shutdown(wait=True, cancel_futures=True)
        self.lease.release()

    def submit(self, job_id: str) -> None:
        if self.pool and not self.stopping.is_set():
            self.pool.submit(self.work, job_id)

    @staticmethod
    def public_job(row) -> dict:
        return {"id": row["id"], "stage": row["stage"], "status": row["status"],
                "progress": row["progress"], "reportId": row["report_id"], "error": row["error"]}

    def owned_job(self, db, job_id: str):
        row = db.execute("SELECT * FROM jobs WHERE id=? AND owner=? AND deleted=0", (job_id, self.owner)).fetchone()
        if not row:
            raise HTTPException(404, "analysis_not_found")
        return row

    def check_operation(self, key: str) -> None:
        if not OPERATION_KEY.fullmatch(key):
            raise HTTPException(422, "valid_idempotency_key_header_required")
        with self.store.transaction() as db:
            operation = db.execute("SELECT cancelled FROM operations WHERE owner=? AND key=?", (self.owner, key)).fetchone()
            if operation and operation["cancelled"]:
                raise HTTPException(410, "operation_cancelled")

    def upload(self, data: bytes, key: str) -> dict:
        self.check_operation(key)
        if len(data) > self.settings.max_upload_bytes:
            raise HTTPException(413, "upload_too_large")
        try:
            with warnings.catch_warnings():
                warnings.simplefilter("error", Image.DecompressionBombWarning)
                with Image.open(io.BytesIO(data)) as source:
                    if source.format not in {"JPEG", "PNG"} or getattr(source, "n_frames", 1) != 1:
                        raise HTTPException(415, "unsupported_image")
                    if source.width * source.height > self.settings.max_pixels:
                        raise HTTPException(413, "too_many_pixels")
                    if min(source.size) < self.settings.min_side:
                        raise HTTPException(422, "image_too_small")
                    source.verify()
                with Image.open(io.BytesIO(data)) as source:
                    image = ImageOps.exif_transpose(source)
                    image.load()
                    if image.mode in {"RGBA", "LA"} or (image.mode == "P" and "transparency" in image.info):
                        rgba = image.convert("RGBA")
                        image = Image.new("RGB", rgba.size, "white")
                        image.paste(rgba, mask=rgba.getchannel("A"))
                    else:
                        image = image.convert("RGB")
                    output = io.BytesIO()
                    image.save(output, "JPEG", quality=95, exif=b"")
                    width, height = image.size
        except HTTPException:
            raise
        except (Image.DecompressionBombWarning, Image.DecompressionBombError):
            raise HTTPException(413, "too_many_pixels") from None
        except (UnidentifiedImageError, OSError, ValueError, SyntaxError):
            raise HTTPException(422, "invalid_image") from None
        asset_id = new_id()
        path = self.store.asset_path(asset_id)
        temp = path.with_suffix(".tmp")
        # Atomic rename + ledger transaction. A crash before the insert leaves a
        # private orphan cleaned at next startup; no client-visible partial asset.
        with self.store.transaction() as db:
            operation = db.execute("SELECT * FROM operations WHERE owner=? AND key=?", (self.owner, key)).fetchone()
            # Cancellation may have arrived while the body was being received or
            # the image was being decoded. This check and the commit share a lock.
            if operation and operation["cancelled"]:
                raise HTTPException(410, "operation_cancelled")
            digest = hashlib.sha256(data).hexdigest()
            if operation and operation["asset_id"]:
                if operation["upload_digest"] != digest:
                    raise HTTPException(409, "idempotency_upload_conflict")
                if not db.execute("SELECT 1 FROM assets WHERE id=? AND owner=?", (operation["asset_id"], self.owner)).fetchone():
                    raise HTTPException(410, "asset_deleted")
                return {"assetId": operation["asset_id"]}
            try:
                temp.write_bytes(output.getvalue())
                temp.replace(path)
                db.execute("INSERT INTO assets VALUES (?,?,?,?,?)", (asset_id, self.owner, width, height, utc_now()))
                db.execute("INSERT INTO operations(owner,key,asset_id,upload_digest,created_at) VALUES (?,?,?,?,?)",
                           (self.owner, key, asset_id, digest, utc_now()))
            except BaseException:
                temp.unlink(missing_ok=True)
                path.unlink(missing_ok=True)
                raise
        return {"assetId": asset_id}

    def create_analysis(self, body: AnalysisRequest) -> dict:
        with self.store.transaction() as db:
            operation = db.execute("SELECT * FROM operations WHERE owner=? AND key=?", (self.owner, body.idempotencyKey)).fetchone()
            if operation and operation["cancelled"]:
                raise HTTPException(410, "operation_cancelled")
            existing = db.execute("SELECT * FROM jobs WHERE owner=? AND idempotency_key=?", (self.owner, body.idempotencyKey)).fetchone()
            if existing:
                if existing["asset_id"] != body.assetId or existing["consent_id"] != body.consentId:
                    raise HTTPException(409, "idempotency_key_conflict")
                if existing["deleted"]:
                    raise HTTPException(410, "analysis_deleted")
                return self.public_job(existing)
            if not db.execute("SELECT 1 FROM assets WHERE id=? AND owner=?", (body.assetId, self.owner)).fetchone():
                raise HTTPException(404, "asset_not_found")
            consent = db.execute("SELECT * FROM consents WHERE id=? AND owner=?", (body.consentId, self.owner)).fetchone()
            if not consent or consent["purpose"] != "skin_appearance_analysis" or consent["version"] != "1.0":
                raise HTTPException(422, "valid_consent_required")
            if not operation or operation["asset_id"] != body.assetId:
                raise HTTPException(409, "asset_operation_mismatch")
            # Avoid accidental duplicate concurrent work for one uploaded photo.
            if db.execute("SELECT 1 FROM jobs WHERE asset_id=? AND owner=? AND deleted=0 AND status IN ('queued','running')", (body.assetId, self.owner)).fetchone():
                raise HTTPException(409, "asset_analysis_in_progress")
            job_id, now = new_id(), utc_now()
            db.execute("""INSERT INTO jobs(id,owner,asset_id,consent_id,idempotency_key,stage,status,progress,created_at,updated_at)
                          VALUES (?,?,?,?,?,'preparing','queued',0,?,?)""",
                       (job_id, self.owner, body.assetId, body.consentId, body.idempotencyKey, now, now))
            response = self.public_job(self.owned_job(db, job_id))
        self.submit(job_id)
        return response

    def work(self, job_id: str) -> None:
        with self.store.transaction() as db:
            row = db.execute("SELECT * FROM jobs WHERE id=? AND owner=? AND deleted=0 AND status='queued'", (job_id, self.owner)).fetchone()
            if not row or self.stopping.is_set():
                return
            asset_id = row["asset_id"]
            db.execute("UPDATE jobs SET status='running', attempt=attempt+1, updated_at=? WHERE id=?", (utc_now(), job_id))

        def progress(stage: str, value: float) -> None:
            with self.store.transaction() as db:
                row = db.execute("SELECT deleted,status FROM jobs WHERE id=? AND owner=?", (job_id, self.owner)).fetchone()
                if self.stopping.is_set() or not row or row["deleted"] or row["status"] != "running":
                    raise Cancelled("cancelled")
                db.execute("UPDATE jobs SET stage=?,progress=?,updated_at=? WHERE id=?", (stage, value, utc_now(), job_id))

        try:
            report = self.analyzer(self.store.asset_path(asset_id), self.settings, progress)
            report_id = new_id()
            report["id"] = report_id
            # Even an injected analyzer cannot write an incompatible wire report.
            report = AnalysisReport.model_validate(report).model_dump()
            with self.store.transaction() as db:
                current = db.execute("SELECT deleted,status FROM jobs WHERE id=? AND owner=?", (job_id, self.owner)).fetchone()
                if self.stopping.is_set() or not current or current["deleted"] or current["status"] != "running":
                    return
                db.execute("INSERT INTO reports VALUES (?,?,?,?,?)", (report_id, self.owner, asset_id, job_id, json.dumps(report, ensure_ascii=False, allow_nan=False)))
                db.execute("UPDATE jobs SET status='completed',stage='report_render',progress=1,report_id=?,error=NULL,updated_at=? WHERE id=?", (report_id, utc_now(), job_id))
        except Cancelled:
            return
        except Exception as error:
            # No raw image, model response, token, path or arbitrary exception
            # string is logged or returned. Fixed allowlisted codes only.
            code = str(error) if isinstance(error, AnalysisFailure) else "analysis_failed"
            allowed = {"model_not_configured", "model_runtime_not_installed", "poor_lighting", "model_inference_failed",
                       "no_face", "multiple_faces", "invalid_model_output", "face_too_small", "skin_models_unavailable"}
            if code not in allowed:
                code = "analysis_failed"
            with self.store.transaction() as db:
                db.execute("UPDATE jobs SET status='failed',error=?,updated_at=? WHERE id=? AND owner=? AND deleted=0 AND status='running'", (code, utc_now(), job_id, self.owner))

    def delete_job(self, db, job_id: str) -> None:
        row = db.execute("SELECT * FROM jobs WHERE id=? AND owner=?", (job_id, self.owner)).fetchone()
        if not row:
            return
        db.execute("DELETE FROM reports WHERE job_id=? AND owner=?", (job_id, self.owner))
        # Keep only a minimal idempotency tombstone, no image/report data.
        db.execute("UPDATE jobs SET deleted=1,status='cancelled',report_id=NULL,error=NULL,progress=0,updated_at=? WHERE id=? AND owner=?", (utc_now(), job_id, self.owner))
        asset_id = row["asset_id"]
        if not db.execute("SELECT 1 FROM jobs WHERE asset_id=? AND owner=? AND deleted=0", (asset_id, self.owner)).fetchone():
            self.store.asset_path(asset_id).unlink(missing_ok=True)
            db.execute("DELETE FROM assets WHERE id=? AND owner=?", (asset_id, self.owner))
            db.execute("UPDATE operations SET cancelled=1 WHERE asset_id=? AND owner=?", (asset_id, self.owner))

    def delete_operation(self, key: str) -> None:
        if not OPERATION_KEY.fullmatch(key):
            raise HTTPException(422, "invalid_operation_key")
        with self.store.transaction() as db:
            # Durable cancel-before-create tombstone. An in-flight upload cannot
            # commit afterwards; a replayed POST cannot resurrect private data.
            db.execute("""INSERT INTO operations(owner,key,cancelled,created_at) VALUES (?,?,1,?)
                          ON CONFLICT(owner,key) DO UPDATE SET cancelled=1""", (self.owner, key, utc_now()))
            operation = db.execute("SELECT asset_id FROM operations WHERE owner=? AND key=?", (self.owner, key)).fetchone()
            jobs = list(db.execute("SELECT id FROM jobs WHERE owner=? AND idempotency_key=?", (self.owner, key)))
            for job in jobs:
                self.delete_job(db, job["id"])
            if operation["asset_id"]:
                asset_id = operation["asset_id"]
                self.store.asset_path(asset_id).unlink(missing_ok=True)
                db.execute("DELETE FROM assets WHERE id=? AND owner=?", (asset_id, self.owner))


def create_app(settings: Settings | None = None, *, analyzer: Callable = analyze, run_workers: bool = True) -> FastAPI:
    settings = settings or Settings.from_env()
    service = Service(settings, analyzer, run_workers=run_workers)

    @asynccontextmanager
    async def lifespan(app):
        service.start()
        yield
        service.close()

    app = FastAPI(title="如愿美学 development backend", lifespan=lifespan,
                  docs_url=None, redoc_url=None, openapi_url=None)
    app.state.service = service
    app.add_middleware(BodyLimitMiddleware, max_bytes=settings.max_upload_bytes + 256 * 1024)
    bearer = HTTPBearer(auto_error=False)

    def authenticate(credentials: HTTPAuthorizationCredentials | None = Depends(bearer)) -> str:
        if not credentials or credentials.scheme.lower() != "bearer" or not secrets.compare_digest(hashlib.sha256(credentials.credentials.encode("utf-8")).hexdigest(), settings.owner):
            raise HTTPException(401, "unauthorized", headers={"WWW-Authenticate": "Bearer"})
        return service.owner

    @app.exception_handler(UploadTooLarge)
    async def too_large(request: Request, error: UploadTooLarge):
        return JSONResponse({"detail": "upload_too_large"}, 413)

    @app.middleware("http")
    async def private_responses(request: Request, call_next):
        response = await call_next(request)
        response.headers["Cache-Control"] = "no-store"
        response.headers["X-Content-Type-Options"] = "nosniff"
        return response

    @app.get("/healthz")
    def health():
        return {"status": "ok", "mode": "single_installation_development",
                "modelConfigured": bool(settings.face_model and settings.face_model.is_file())}

    @app.get("/v1/models", dependencies=[Depends(authenticate)])
    def model_status():
        from .trained_skin import availability
        return {"models": availability(settings.skin_models_dir), "automaticDownloads": False}

    @app.post("/v1/uploads", dependencies=[Depends(authenticate)], status_code=201)
    async def upload(request: Request):
        key = request.headers.get("Idempotency-Key", "")
        service.check_operation(key)
        async with request.form(max_files=1, max_fields=0) as form:
            photo = form.get("file")
            if not isinstance(photo, UploadFile) or len(form) != 1:
                raise HTTPException(422, "one_file_required")
            data = await photo.read(settings.max_upload_bytes + 1)
            return await run_in_threadpool(service.upload, data, key)

    @app.post("/v1/consents", dependencies=[Depends(authenticate)], status_code=201)
    def consent(body: ConsentRequest):
        consent_id = new_id()
        with service.store.transaction() as db:
            db.execute("INSERT INTO consents VALUES (?,?,?,?,?)", (consent_id, service.owner, body.purpose, body.version, utc_now()))
        return {"consentId": consent_id}

    @app.post("/v1/analyses", dependencies=[Depends(authenticate)], status_code=202)
    def create_analysis(body: AnalysisRequest):
        return service.create_analysis(body)

    @app.get("/v1/analyses/{job_id}", dependencies=[Depends(authenticate)])
    def get_analysis(job_id: str):
        with service.store.transaction() as db:
            return service.public_job(service.owned_job(db, job_id))

    @app.get("/v1/reports/{report_id}", dependencies=[Depends(authenticate)], response_model=AnalysisReport)
    def get_report(report_id: str):
        with service.store.transaction() as db:
            row = db.execute("SELECT body FROM reports WHERE id=? AND owner=?", (report_id, service.owner)).fetchone()
            if not row:
                raise HTTPException(404, "report_not_found")
            return json.loads(row["body"])

    @app.get("/v1/assets/{asset_id}", dependencies=[Depends(authenticate)])
    def get_asset(asset_id: str):
        with service.store.transaction() as db:
            if not ID.fullmatch(asset_id) or not db.execute("SELECT 1 FROM assets WHERE id=? AND owner=?", (asset_id, service.owner)).fetchone():
                raise HTTPException(404, "asset_not_found")
            try:
                data = service.store.asset_path(asset_id).read_bytes()
            except FileNotFoundError:
                raise HTTPException(404, "asset_not_found") from None
        return Response(data, media_type="image/jpeg", headers={"Content-Disposition": f'inline; filename="{asset_id}.jpg"'})

    @app.delete("/v1/analyses/{job_id}", dependencies=[Depends(authenticate)], status_code=204)
    def delete_analysis(job_id: str):
        with service.store.transaction() as db:
            service.delete_job(db, job_id)
        return Response(status_code=204)

    @app.delete("/v1/reports/{report_id}", dependencies=[Depends(authenticate)], status_code=204)
    def delete_report(report_id: str):
        with service.store.transaction() as db:
            row = db.execute("SELECT job_id FROM reports WHERE id=? AND owner=?", (report_id, service.owner)).fetchone()
            if row:
                service.delete_job(db, row["job_id"])
        return Response(status_code=204)

    @app.delete("/v1/assets/{asset_id}", dependencies=[Depends(authenticate)], status_code=204)
    def delete_asset(asset_id: str):
        with service.store.transaction() as db:
            if ID.fullmatch(asset_id) and db.execute("SELECT 1 FROM assets WHERE id=? AND owner=?", (asset_id, service.owner)).fetchone():
                if db.execute("SELECT 1 FROM jobs WHERE asset_id=? AND owner=? AND deleted=0", (asset_id, service.owner)).fetchone():
                    raise HTTPException(409, "asset_in_use_delete_analysis_first")
                service.store.asset_path(asset_id).unlink(missing_ok=True)
                db.execute("DELETE FROM assets WHERE id=? AND owner=?", (asset_id, service.owner))
                db.execute("UPDATE operations SET cancelled=1 WHERE asset_id=? AND owner=?", (asset_id, service.owner))
        return Response(status_code=204)

    @app.delete("/v1/operations/{key}", dependencies=[Depends(authenticate)], status_code=204)
    def delete_operation(key: str):
        service.delete_operation(key)
        return Response(status_code=204)

    return app
