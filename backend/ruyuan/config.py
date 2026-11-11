from __future__ import annotations

import hashlib
import os
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Settings:
    api_token: str
    data_dir: Path
    face_model: Path | None = None
    max_upload_bytes: int = 20 * 1024 * 1024
    max_pixels: int = 24_000_000
    min_side: int = 256
    workers: int = 1

    def __post_init__(self) -> None:
        if len(self.api_token) < 32 or self.api_token.strip() != self.api_token:
            raise ValueError("RUYUAN_API_TOKEN must be a private random token of at least 32 characters")
        if not 1 <= self.workers <= 2:
            raise ValueError("Development backend supports 1 or 2 worker threads only")
        if self.max_upload_bytes < 1 or self.max_pixels < 1 or self.min_side < 1:
            raise ValueError("Invalid upload limits")

    @property
    def owner(self) -> str:
        return hashlib.sha256(self.api_token.encode("utf-8")).hexdigest()

    @classmethod
    def from_env(cls) -> "Settings":
        model = os.getenv("RUYUAN_FACE_MODEL", "").strip()
        return cls(
            api_token=os.getenv("RUYUAN_API_TOKEN", ""),
            data_dir=Path(os.getenv("RUYUAN_DATA_DIR", "./private-data")).resolve(),
            face_model=Path(model).expanduser().resolve() if model else None,
            workers=int(os.getenv("RUYUAN_WORKERS", "1")),
        )
