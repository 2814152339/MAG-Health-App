from __future__ import annotations

import sqlite3
import threading
from contextlib import contextmanager
from pathlib import Path
from typing import Iterator


class Store:
    """One-process SQLite ledger. Never use multiple Uvicorn worker processes."""

    def __init__(self, root: Path) -> None:
        self.root = root.resolve()
        self.assets = self.root / "assets"
        self.assets.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.path = self.root / "ledger.sqlite3"
        self.lock = threading.RLock()
        with self.transaction() as db:
            db.executescript("""
                PRAGMA journal_mode=WAL;
                CREATE TABLE IF NOT EXISTS assets (
                    id TEXT PRIMARY KEY, owner TEXT NOT NULL,
                    width INTEGER NOT NULL, height INTEGER NOT NULL,
                    created_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS consents (
                    id TEXT PRIMARY KEY, owner TEXT NOT NULL,
                    purpose TEXT NOT NULL, version TEXT NOT NULL,
                    created_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS jobs (
                    id TEXT PRIMARY KEY, owner TEXT NOT NULL,
                    asset_id TEXT NOT NULL, consent_id TEXT NOT NULL,
                    idempotency_key TEXT NOT NULL, stage TEXT NOT NULL,
                    status TEXT NOT NULL, progress REAL NOT NULL,
                    report_id TEXT, error TEXT, attempt INTEGER NOT NULL DEFAULT 0,
                    deleted INTEGER NOT NULL DEFAULT 0,
                    created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
                    UNIQUE(owner, idempotency_key)
                );
                CREATE TABLE IF NOT EXISTS reports (
                    id TEXT PRIMARY KEY, owner TEXT NOT NULL,
                    asset_id TEXT NOT NULL, job_id TEXT NOT NULL UNIQUE,
                    body TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS operations (
                    owner TEXT NOT NULL, key TEXT NOT NULL,
                    asset_id TEXT, upload_digest TEXT,
                    cancelled INTEGER NOT NULL DEFAULT 0,
                    created_at TEXT NOT NULL,
                    PRIMARY KEY(owner, key)
                );
                CREATE INDEX IF NOT EXISTS jobs_owner ON jobs(owner, deleted);
            """)

    @contextmanager
    def transaction(self) -> Iterator[sqlite3.Connection]:
        with self.lock:
            db = sqlite3.connect(self.path, timeout=30)
            db.row_factory = sqlite3.Row
            try:
                db.execute("PRAGMA foreign_keys=ON")
                db.execute("BEGIN IMMEDIATE")
                yield db
                db.commit()
            except BaseException:
                db.rollback()
                raise
            finally:
                db.close()

    def asset_path(self, asset_id: str) -> Path:
        # IDs are generated here, not paths supplied by the caller.
        import re

        if not re.fullmatch(r"[0-9a-f]{32}", asset_id):
            raise ValueError("invalid_asset_id")
        path = (self.assets / f"{asset_id}.jpg").resolve()
        if path.parent != self.assets.resolve():
            raise ValueError("invalid_asset_path")
        return path
