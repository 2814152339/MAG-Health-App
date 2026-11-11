"""Wire models deliberately match iOS/Ruyuan/Models/AnalysisModels.swift."""
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid", allow_inf_nan=False)


class ConsentRequest(StrictModel):
    purpose: Literal["skin_appearance_analysis"]
    version: Literal["1.0"]


class AnalysisRequest(StrictModel):
    assetId: str = Field(pattern=r"^[0-9a-f]{32}$")
    consentId: str = Field(pattern=r"^[0-9a-f]{32}$")
    idempotencyKey: str = Field(min_length=8, max_length=128, pattern=r"^[A-Za-z0-9_.:-]+$")


class Point(StrictModel):
    x: float = Field(ge=0, le=1)
    y: float = Field(ge=0, le=1)


class GeometryMetric(StrictModel):
    id: str
    title: str
    value: float | None
    unit: str
    note: str


class SkinItem(StrictModel):
    id: str
    title: str
    valueText: str
    note: str
    overlayID: str | None = None


class SkinMetric(StrictModel):
    dimension: Literal["waterOil", "tone", "sensitivity", "smoothness", "aging"]
    score: float | None
    status: str
    items: list[SkinItem]


class LandmarkPath(StrictModel):
    id: str
    points: list[Point]
    closed: bool


class OverlayLayer(StrictModel):
    id: str
    title: str
    colorHex: str
    kind: Literal["polygons", "lines", "points"]
    paths: list[list[Point]]
    note: str
    source: str


class QualityCheck(StrictModel):
    id: str
    title: str
    passed: bool
    detail: str


class AnalysisReport(StrictModel):
    id: str
    createdAt: str
    origin: Literal["server"]
    status: str
    imageFileName: str
    imageWidth: int
    imageHeight: int
    geometry: list[GeometryMetric]
    skin: list[SkinMetric]
    landmarks: list[LandmarkPath]
    overlays: list[OverlayLayer]
    quality: list[QualityCheck]
    modelVersion: str
    summary: str
