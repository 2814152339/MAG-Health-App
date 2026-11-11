"""Real image measurements, NOT dermatology, hydration or biological-age models.

No model is downloaded at runtime. A compatible, operator-authorized MediaPipe
Face Landmarker task bundle must be explicitly configured.
"""
from __future__ import annotations

import hashlib
import math
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable

import numpy as np
from PIL import Image, ImageDraw

from .config import Settings
from .schemas import AnalysisReport


class AnalysisFailure(Exception):
    """Only this stable code, never exception data / file paths, goes to clients."""


class Cancelled(AnalysisFailure):
    pass


FACE_OVAL = [10, 338, 297, 332, 284, 251, 389, 356, 454, 323, 361, 288,
             397, 365, 379, 378, 400, 377, 152, 148, 176, 149, 150, 136,
             172, 58, 132, 93, 234, 127, 162, 21, 54, 103, 67, 109]
LEFT_EYE = [33, 160, 158, 133, 153, 144]
RIGHT_EYE = [362, 385, 387, 263, 373, 380]
LIPS = [61, 40, 37, 0, 267, 270, 291, 321, 314, 17, 84, 91]
CHEEKS = [[50, 101, 205, 187, 123, 116, 117, 118],
          [280, 330, 425, 411, 352, 345, 346, 347]]


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def analyze(path: Path, settings: Settings, progress: Callable[[str, float], None]) -> dict:
    model = settings.face_model
    if not model or not model.is_file():
        raise AnalysisFailure("model_not_configured")
    try:
        import mediapipe as mp
        from mediapipe.tasks.python import BaseOptions
        from mediapipe.tasks.python.vision import FaceLandmarker, FaceLandmarkerOptions, RunningMode
    except ImportError:
        raise AnalysisFailure("model_runtime_not_installed") from None

    progress("quality_checking", 0.15)
    with Image.open(path) as image:
        image = image.convert("RGB")
        original_width, original_height = image.size
        # Bounded processing memory; coordinates remain normalized to the upright
        # original, whose aspect ratio is retained by thumbnail().
        image.thumbnail((1600, 1600), Image.Resampling.LANCZOS)
        rgb = np.asarray(image).copy()
    height, width = rgb.shape[:2]
    luminance = rgb @ np.array([0.2126, 0.7152, 0.0722])
    if float(luminance.mean()) < 25 or float(luminance.mean()) > 245:
        raise AnalysisFailure("poor_lighting")

    progress("geometry", 0.35)
    try:
        options = FaceLandmarkerOptions(
            base_options=BaseOptions(model_asset_path=str(model)),
            running_mode=RunningMode.IMAGE, num_faces=2,
            min_face_detection_confidence=0.6,
            min_face_presence_confidence=0.6,
            output_face_blendshapes=False,
            output_facial_transformation_matrixes=False,
        )
        with FaceLandmarker.create_from_options(options) as detector:
            result = detector.detect(mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb))
    except Exception:
        raise AnalysisFailure("model_inference_failed") from None
    if not result.face_landmarks:
        raise AnalysisFailure("no_face")
    if len(result.face_landmarks) != 1:
        raise AnalysisFailure("multiple_faces")
    landmarks = result.face_landmarks[0]
    if len(landmarks) < 468:
        raise AnalysisFailure("invalid_model_output")
    pts = [{"x": max(0.0, min(1.0, float(p.x))),
            "y": max(0.0, min(1.0, float(p.y)))} for p in landmarks]

    def dist(a: int, b: int) -> float:
        return math.hypot((pts[a]["x"] - pts[b]["x"]) * original_width,
                          (pts[a]["y"] - pts[b]["y"]) * original_height)

    face_width, face_height = dist(234, 454), dist(10, 152)
    if min(face_width, face_height) < 40:
        raise AnalysisFailure("face_too_small")
    face_coverage = face_width / original_width
    geometry = [
        {"id": "face_aspect", "title": "面部宽高比", "value": face_width / face_height,
         "unit": "", "note": "面颊外侧关键点距离 ÷ 额顶至下巴距离；受发型、姿态和透视影响。"},
        {"id": "eye_spacing", "title": "内眼角间距 / 脸宽", "value": dist(133, 362) / face_width,
         "unit": "", "note": "单张二维照片的关键点比例，不代表审美标准。"},
        {"id": "mouth_width", "title": "口宽 / 脸宽", "value": dist(61, 291) / face_width,
         "unit": "", "note": "自然表情下才适合重复比较；不推断治疗需求。"},
    ]
    paths = [{"id": name, "points": [pts[i] for i in indices], "closed": True}
             for name, indices in [("face", FACE_OVAL), ("leftEye", LEFT_EYE),
                                   ("rightEye", RIGHT_EYE), ("lips", LIPS)]]
    progress("skin_models", 0.65)
    mask_image = Image.new("L", (width, height), 0)
    draw = ImageDraw.Draw(mask_image)
    for cheek in CHEEKS:
        draw.polygon([(pts[i]["x"] * width, pts[i]["y"] * height) for i in cheek], fill=255)
    mask = np.asarray(mask_image) > 0
    if int(mask.sum()) < 32:
        raise AnalysisFailure("face_too_small")
    pixels = rgb.astype(np.float64)
    redness = (pixels[:, :, 0] - pixels[:, :, 1]) / np.maximum(pixels.sum(axis=2), 1.0)
    bright_threshold = float(np.percentile(luminance[mask], 80))
    red_threshold = float(np.percentile(redness[mask], 80))
    # These are image-relative thresholds, not lesion segmentation or validated
    # population thresholds. Require positive excess red / strong brightness.
    bright_mask = mask & (luminance >= max(190, bright_threshold))
    red_mask = mask & (redness >= max(0.06, red_threshold))

    def tiles(binary: np.ndarray) -> list[list[dict]]:
        polygons = []
        step = max(8, math.ceil(max(width, height) / 48))
        for y in range(0, height, step):
            for x in range(0, width, step):
                block = binary[y:y + step, x:x + step]
                if block.size and float(block.mean()) >= 0.6:
                    x1, y1 = min(x + step, width), min(y + step, height)
                    polygons.append([{"x": x / width, "y": y / height},
                                     {"x": x1 / width, "y": y / height},
                                     {"x": x1 / width, "y": y1 / height},
                                     {"x": x / width, "y": y1 / height}])
        return polygons

    proxy_note = "仅为此照片双颊采样区的颜色/亮度代理，受光线、白平衡、妆容影响，不是医学测量。"
    overlays = [
        {"id": "bright_proxy", "title": "相对明亮区域", "colorHex": "#E7C979", "kind": "polygons",
         "paths": tiles(bright_mask), "note": proxy_note + "不等于皮脂或含水量。", "source": "pixel_brightness_proxy_v1"},
        {"id": "red_proxy", "title": "相对偏红区域", "colorHex": "#D98585", "kind": "polygons",
         "paths": tiles(red_mask), "note": proxy_note + "不等于敏感、炎症或病变。", "source": "pixel_redness_proxy_v1"},
    ]

    def item(id: str, title: str, value: str, note: str, overlay: str | None = None) -> dict:
        return {"id": id, "title": title, "valueText": value, "note": note, "overlayID": overlay}

    skin = [
        {"dimension": "waterOil", "score": None, "status": "未测量水油度", "items": [
            item("brightness", "双颊明亮像素占比", f"{bright_mask.sum() / mask.sum() * 100:.1f}%", proxy_note + "不代表出油量。", "bright_proxy"),
            item("hydration", "含水量 / 皮脂量", "未测量", "单张普通RGB照片无法测得，需适用仪器。") ]},
        {"dimension": "tone", "score": None, "status": "仅图像亮度观察", "items": [
            item("luminance", "双颊平均图像亮度", f"{luminance[mask].mean():.1f} / 255", proxy_note)]},
        {"dimension": "sensitivity", "score": None, "status": "未评估敏感性", "items": [
            item("redness", "双颊相对偏红像素占比", f"{red_mask.sum() / mask.sum() * 100:.1f}%", proxy_note + "不能诊断敏感。", "red_proxy")]},
        {"dimension": "smoothness", "score": None, "status": "未测量", "items": [
            item("texture", "毛孔 / 痘痘 / 平滑度", "待专业评估", "未配置且未验证相应分割模型，不生成虚假分数或斑点。") ]},
        {"dimension": "aging", "score": None, "status": "未测量", "items": [
            item("age", "皱纹 / 衰老程度", "待专业评估", "未配置且未验证临床模型，不推断生理年龄或治疗需求。") ]},
    ]
    nose_offset = abs(pts[1]["x"] - (pts[33]["x"] + pts[263]["x"]) / 2) / max(face_width / original_width, 1e-9)
    quality = [
        {"id": "one_face", "title": "单人脸", "passed": True, "detail": "MediaPipe检测到一张人脸。"},
        {"id": "size", "title": "面部占比", "passed": face_coverage >= 0.25,
         "detail": f"脸宽约占图像宽度 {face_coverage * 100:.0f}%；建议更近距离拍摄。"},
        {"id": "lighting", "title": "整体曝光", "passed": 55 <= luminance.mean() <= 215,
         "detail": "仅检查图像平均亮度，不校准色彩。"},
        {"id": "pose", "title": "正面姿态提示", "passed": nose_offset < 0.15,
         "detail": "以鼻点和外眼角的二维偏移作粗略提示，不是已标定三维姿态。"},
    ]
    progress("report_render", 0.9)
    # Fingerprint the explicitly supplied model, not a fabricated version label.
    model_digest = hashlib.sha256(model.read_bytes()).hexdigest()[:12]
    report = {"id": "", "createdAt": utc_now(), "origin": "server", "status": "partial",
              "imageFileName": path.name, "imageWidth": original_width, "imageHeight": original_height,
              "geometry": geometry, "skin": skin, "landmarks": paths, "overlays": overlays,
              "quality": quality, "modelVersion": f"MediaPipe-{mp.__version__}-face-task-{model_digest};pixel-proxies-v1",
              "summary": "已完成真实人脸关键点、二维比例和双颊亮度/颜色观察。五项皮肤临床分数均未测量；本报告不用于诊断、治疗决策或审美打分。"}
    return AnalysisReport.model_validate(report).model_dump()
