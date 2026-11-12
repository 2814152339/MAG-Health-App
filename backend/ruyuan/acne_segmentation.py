"""Independent, pinned RihemXX/Acnes binary pixel-candidate inference.

Only a SHA-verified tensor state_dict is loaded (weights_only=True). The author
notebook is reference data, never executable input. No network request, training,
fallback heatmap, severity grading, or shared-pipeline registration occurs here.
The output is an acne-related candidate probability map, not lesion subtypes.
"""
from __future__ import annotations

from dataclasses import dataclass
import hashlib
from pathlib import Path
import threading
import time

import numpy as np
from PIL import Image, ImageOps
import torch
from torch import nn

MODEL_ID = 'rihem_acne_segmentation'
REPOSITORY = 'RihemXX/Acnes'
REVISION = '79182ede8d14cb44de63b4f6ace1fa2a5a7a3d83'
AUTHOR_GITHUB = 'rihem-bs02/Acnes'
AUTHOR_GITHUB_REVISION = '826e2adfc7d85c4cf9f3ffa3a68b82d24d3baeb7'
WEIGHT_SHA256 = 'c58a6af6fb622d916e4aa788d9f620d59df4a42209f655ce4a9db49686c05697'
WEIGHT_BYTES = 97_920_000
LICENSE = 'Apache-2.0'
INPUT_SIZE = (256, 256)  # width, height; author uses stretched OpenCV INTER_LINEAR
MEAN = (0.485, 0.456, 0.406)
STD = (0.229, 0.224, 0.225)
THRESHOLD = 0.20  # strictly greater than, as in the author's display code
PARAMETER_COUNT = 24_436_369
DATA_NOTICE = 'Complete training-image provenance, consent, subject split and pixel GT not disclosed by author.'


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


class RGBAcneSegmentation(nn.Module):
    """RGB [0,1] NCHW -> sigmoid probabilities; normalization embedded."""
    def __init__(self, network: nn.Module):
        super().__init__()
        self.network = network
        self.register_buffer('mean', torch.tensor(MEAN).reshape(1, 3, 1, 1))
        self.register_buffer('std', torch.tensor(STD).reshape(1, 3, 1, 1))

    def forward(self, image: torch.Tensor) -> torch.Tensor:
        return torch.sigmoid(self.network((image - self.mean) / self.std))


def load_verified_model(path: Path) -> RGBAcneSegmentation:
    """No arbitrary Python pickle globals and no pretrained-encoder download."""
    if not path.is_file() or path.stat().st_size != WEIGHT_BYTES:
        raise ValueError('acne_segmentation_weights_missing_or_wrong_size')
    if sha256_file(path) != WEIGHT_SHA256:
        raise ValueError('acne_segmentation_weight_digest_mismatch')
    # Keep this specialist dependency optional for existing backend installations.
    import segmentation_models_pytorch as smp
    state = torch.load(path, map_location='cpu', weights_only=True)
    if not isinstance(state, dict) or not state or not all(
        isinstance(key, str) and isinstance(value, torch.Tensor)
        for key, value in state.items()
    ):
        raise ValueError('acne_segmentation_expected_tensor_state_dict')
    network = smp.Unet(encoder_name='resnet34', encoder_weights=None, in_channels=3, classes=1)
    network.load_state_dict(state, strict=True)
    if sum(p.numel() for p in network.parameters()) != PARAMETER_COUNT:
        raise ValueError('acne_segmentation_architecture_mismatch')
    return RGBAcneSegmentation(network).eval()


def image_tensor(image: Image.Image) -> torch.Tensor:
    """Author resize: uint8 RGB -> OpenCV INTER_LINEAR -> floats in [0,1].

    The wrapper, not this function, applies ImageNet mean/std. EXIF orientation
    is resolved before resize. The returned map coordinates refer to the upright
    source image, stretched into the fixed 256 x 256 input, not a padded crop.
    """
    import cv2
    rgb = np.asarray(ImageOps.exif_transpose(image).convert('RGB'), dtype=np.uint8)
    resized = cv2.resize(rgb, INPUT_SIZE, interpolation=cv2.INTER_LINEAR)
    array = resized.astype(np.float32).transpose(2, 0, 1)[None].copy() / 255.0
    return torch.from_numpy(array)


def candidate_mask(probability: np.ndarray, *, skin_roi: np.ndarray | None = None) -> np.ndarray:
    """Threshold without dilation/retouching; optional explicit 256x256 skin ROI."""
    array = np.asarray(probability)
    if array.shape != (INPUT_SIZE[1], INPUT_SIZE[0]):
        raise ValueError('acne_segmentation_probability_shape_mismatch')
    if not np.isfinite(array).all() or array.min() < 0 or array.max() > 1:
        raise ValueError('acne_segmentation_invalid_probability')
    mask = array > THRESHOLD
    if skin_roi is not None:
        roi = np.asarray(skin_roi)
        if roi.shape != array.shape or roi.dtype != np.bool_:
            raise ValueError('acne_segmentation_roi_requires_bool_256x256')
        mask &= roi
    return mask


@dataclass(frozen=True)
class AcneSegmentationResult:
    probability: np.ndarray
    candidates: np.ndarray
    inference_seconds: float
    roi_applied: bool

    def observation(self) -> dict:
        """Metadata only; do not serialize the entire float map into an item."""
        return {
            'id': MODEL_ID, 'label': '痘相关像素候选', 'source': REPOSITORY,
            'revision': REVISION, 'sourceSHA256': WEIGHT_SHA256, 'license': LICENSE,
            'kind': 'trainedBinarySegmentation', 'threshold': THRESHOLD,
            'outputShape': [1, 1, INPUT_SIZE[1], INPUT_SIZE[0]],
            'candidatePixels': int(self.candidates.sum()),
            'candidatePixelFraction': float(self.candidates.mean()),
            'probabilityMin': float(self.probability.min()),
            'probabilityMax': float(self.probability.max()),
            'roiApplied': self.roi_applied, 'inferenceSeconds': self.inference_seconds,
            'trainingDataNotice': DATA_NOTICE,
        }


class AcneSegmentationService:
    """Explicit optional model readiness; failure never substitutes CV candidates."""
    def __init__(self, weight_path: Path):
        self.weight_path = Path(weight_path)
        self._model: RGBAcneSegmentation | None = None
        self._state = 'not_loaded'
        self._error_code: str | None = None
        self._lock = threading.RLock()

    def status(self) -> dict:
        with self._lock:
            return {'id': MODEL_ID, 'state': self._state, 'errorCode': self._error_code,
                    'repository': REPOSITORY, 'revision': REVISION, 'sourceSHA256': WEIGHT_SHA256}

    def load(self) -> None:
        with self._lock:
            if self._model is not None:
                return
            try:
                model = load_verified_model(self.weight_path)
            except (ImportError, ModuleNotFoundError):
                self._state, self._error_code = 'unavailable', 'optional_dependency_missing'
                raise
            except Exception:
                self._state, self._error_code = 'unavailable', 'model_validation_failed'
                raise
            self._model, self._state, self._error_code = model, 'ready', None

    def analyze(self, image: Image.Image, *, skin_roi: np.ndarray | None = None) -> AcneSegmentationResult:
        with self._lock:
            self.load()
            tensor = image_tensor(image)
            started = time.perf_counter()
            with torch.inference_mode():
                output = self._model(tensor).cpu().numpy()
            elapsed = time.perf_counter() - started
            if output.shape != (1, 1, INPUT_SIZE[1], INPUT_SIZE[0]):
                raise ValueError('acne_segmentation_runtime_shape_mismatch')
            probability = output[0, 0].copy()
            mask = candidate_mask(probability, skin_roi=skin_roi)
            return AcneSegmentationResult(probability, mask, elapsed, skin_roi is not None)
