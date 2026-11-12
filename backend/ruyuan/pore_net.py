"""Pinned Pore-Net inference, independent from the existing three classifiers.

Architecture adapted from ZombaSY/Pore-Net-release, Apache-2.0,
commit 6f851e0d911bd73f41dd905c685129b13d52e1bc, models/model.py.
Changes: omit training initializers/imports, remove DataParallel wrapper, and
embed author RGB normalization for a single portable image-input contract.
No downloaded Python source is executed. Only weights_only tensor state loads.
"""
from __future__ import annotations

import hashlib
from pathlib import Path

import numpy as np
from PIL import Image
import torch
from torch import nn
from torch.nn import functional as F

REVISION = '6f851e0d911bd73f41dd905c685129b13d52e1bc'
WEIGHT_SHA256 = 'a2d0f5f20eee45197612d55d2404ef988832dbcd50dc949bfcd16f5978711da7'
WEIGHT_BYTES = 27390
INPUT_SIZE = (1024, 1280)  # width, height; author inference.yml is [height,width]
MEAN = (0.512, 0.459, 0.353)
STD = (0.254, 0.226, 0.219)
THRESHOLD = 0.25


class PoreNet(nn.Module):
    """Original 4,793-parameter PoreNet_SC architecture, normalized RGB input."""
    def __init__(self):
        super().__init__()
        self.conv1 = nn.Sequential(nn.Conv2d(3, 8, 7, padding=3), nn.BatchNorm2d(8), nn.ReLU(), nn.MaxPool2d(2, 2))
        self.conv2 = nn.Sequential(nn.Conv2d(8, 16, 3, padding=1), nn.BatchNorm2d(16), nn.ReLU())
        self.conv3 = nn.Sequential(nn.Conv2d(16, 16, 3, padding=1), nn.BatchNorm2d(16), nn.ReLU())
        self.decoder = nn.Sequential(nn.Conv2d(40, 1, 1), nn.Sigmoid())

    def forward(self, image):
        a = self.conv1(image)
        b = self.conv2(a)
        c = self.conv3(b)
        probability = self.decoder(torch.cat((a, b, c), dim=1))
        return F.interpolate(probability, size=image.shape[2:], mode='bilinear', align_corners=False)


class RGBPoreNet(nn.Module):
    """Public portable contract: RGB floats in [0,1], output pixel probability."""
    def __init__(self, model: PoreNet):
        super().__init__()
        self.network = model
        self.register_buffer('mean', torch.tensor(MEAN).reshape(1, 3, 1, 1))
        self.register_buffer('std', torch.tensor(STD).reshape(1, 3, 1, 1))

    def forward(self, image):
        return self.network((image - self.mean) / self.std)


def load_verified_model(path: Path) -> RGBPoreNet:
    if not path.is_file() or path.stat().st_size != WEIGHT_BYTES:
        raise ValueError('pore_net_weights_missing_or_wrong_size')
    if hashlib.sha256(path.read_bytes()).hexdigest() != WEIGHT_SHA256:
        raise ValueError('pore_net_weight_digest_mismatch')
    state = torch.load(path, map_location='cpu', weights_only=True)
    model = PoreNet()
    model.load_state_dict({key.removeprefix('module.'): value for key, value in state.items()}, strict=True)
    return RGBPoreNet(model).eval()


def image_tensor(image: Image.Image) -> torch.Tensor:
    rgb = image.convert('RGB').resize(INPUT_SIZE, Image.Resampling.BILINEAR)
    array = np.asarray(rgb, dtype=np.float32).transpose(2, 0, 1)[None].copy() / 255.0
    return torch.from_numpy(array)


def mask_metrics(probability: np.ndarray, target: np.ndarray, roi: np.ndarray, threshold: float) -> dict:
    """Foreground IoU/Dice only; no background-dominated 'pixel accuracy'."""
    if probability.shape != target.shape or probability.shape != roi.shape:
        raise ValueError('pore_net_mask_shape_mismatch')
    prediction = (probability > threshold) & roi.astype(bool)
    ground_truth = target.astype(bool) & roi.astype(bool)
    tp = int(np.count_nonzero(prediction & ground_truth))
    fp = int(np.count_nonzero(prediction & ~ground_truth))
    fn = int(np.count_nonzero(~prediction & ground_truth))
    return {'threshold': threshold, 'truePositivePixels': tp, 'falsePositivePixels': fp,
            'falseNegativePixels': fn, 'foregroundIoU': tp/max(1, tp+fp+fn),
            'foregroundDice': 2*tp/max(1, 2*tp+fp+fn), 'predictedPixels': int(prediction.sum()),
            'targetPixels': int(ground_truth.sum())}
