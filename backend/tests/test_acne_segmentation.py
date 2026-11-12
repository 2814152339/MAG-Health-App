"""Specialist module contract tests; no network and no private photographs."""
from pathlib import Path

import numpy as np
from PIL import Image
import pytest

torch = pytest.importorskip('torch')
from ruyuan.acne_segmentation import (
    AcneSegmentationService, INPUT_SIZE, MEAN, PARAMETER_COUNT,
    RGBAcneSegmentation, STD, THRESHOLD, candidate_mask, image_tensor, load_verified_model,
)


def test_normalization_and_sigmoid_are_embedded_once():
    class FirstChannel(torch.nn.Module):
        def forward(self, x): return x[:, :1]
    model = RGBAcneSegmentation(FirstChannel()).eval()
    value = model(torch.zeros((1, 3, 4, 4)))
    assert value.shape == (1, 1, 4, 4)
    assert float(value[0, 0, 0, 0]) == pytest.approx(float(torch.sigmoid(torch.tensor(-MEAN[0]/STD[0]))))


def test_resize_uses_opencv_linear_without_normalizing_twice():
    cv2 = pytest.importorskip('cv2')
    pixels = np.arange(11*9*3, dtype=np.uint16).reshape(11, 9, 3).astype(np.uint8)
    x = image_tensor(Image.fromarray(pixels))
    expected = cv2.resize(pixels, INPUT_SIZE, interpolation=cv2.INTER_LINEAR)
    assert x.shape == (1, 3, 256, 256) and x.dtype == torch.float32
    assert np.array_equal(x.numpy(), expected.astype(np.float32).transpose(2, 0, 1)[None]/255)


def test_probability_threshold_is_strict_and_roi_is_not_inferred():
    probability = np.zeros((256, 256), dtype=np.float32)
    probability[10, 20], probability[10, 21] = THRESHOLD, .9
    assert int(candidate_mask(probability).sum()) == 1
    roi = np.ones((256, 256), dtype=bool); roi[10, 21] = False
    assert not candidate_mask(probability, skin_roi=roi).any()
    with pytest.raises(ValueError, match='roi_requires_bool'):
        candidate_mask(probability, skin_roi=roi.astype(np.uint8))
    with pytest.raises(ValueError, match='shape_mismatch'):
        candidate_mask(probability[:12])
    probability[0, 0] = np.nan
    with pytest.raises(ValueError, match='invalid_probability'):
        candidate_mask(probability)


def test_unverified_weights_never_reach_torch_load(tmp_path, monkeypatch):
    path = tmp_path/'fake.pth'; path.write_bytes(b'not weights')
    def forbidden(*args, **kwargs): raise AssertionError('unsafe load reached')
    monkeypatch.setattr(torch, 'load', forbidden)
    with pytest.raises(ValueError, match='wrong_size'):
        load_verified_model(path)
    service = AcneSegmentationService(path)
    assert service.status()['state'] == 'not_loaded'
    with pytest.raises(ValueError): service.load()
    assert service.status()['state'] == 'unavailable'
    assert service.status()['errorCode'] == 'model_validation_failed'


def test_optional_real_weight_public_sample_and_synthetic_empty():
    pytest.importorskip('segmentation_models_pytorch')
    folder = Path(__file__).resolve().parents[2]/'.build/model-research/acnes-seg'
    if not (folder/'Acnes_model.pth').is_file():
        pytest.skip('Optional reviewed public state_dict not downloaded')
    torch.set_num_threads(3)
    service = AcneSegmentationService(folder/'Acnes_model.pth')
    blank = service.analyze(Image.new('RGB', (256, 256), (182, 137, 111)))
    assert service.status()['state'] == 'ready'
    assert not blank.candidates.any() and blank.probability.shape == (256, 256)
    assert sum(v.numel() for v in service._model.parameters()) == PARAMETER_COUNT
    if (folder/'original.jpg').is_file():
        result = service.analyze(Image.open(folder/'original.jpg'))
        assert np.isfinite(result.probability).all() and result.probability.max() > THRESHOLD
        assert 0 < result.candidates.sum() < 65536
        assert result.observation()['kind'] == 'trainedBinarySegmentation'
        assert result.observation()['roiApplied'] is False
        assert 'accuracy' not in result.observation()
