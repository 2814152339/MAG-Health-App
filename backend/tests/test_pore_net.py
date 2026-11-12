"""Offline contract checks plus an optional real pinned-weight smoke test."""
from pathlib import Path

import numpy as np
from PIL import Image
import pytest

torch = pytest.importorskip('torch')
from ruyuan.pore_net import INPUT_SIZE, REVISION, PoreNet, RGBPoreNet, image_tensor, load_verified_model, mask_metrics


def test_exact_parameter_count_and_probability_shape():
    model = RGBPoreNet(PoreNet()).eval()
    assert sum(p.numel() for p in model.parameters()) == 4793
    with torch.inference_mode():
        output = model(torch.zeros((1, 3, 32, 24)))
    assert output.shape == (1, 1, 32, 24)
    assert torch.isfinite(output).all() and output.min() >= 0 and output.max() <= 1


def test_image_contract_rgb_unit_range_and_original_size():
    x = image_tensor(Image.new('RGB', (31, 29), (255, 128, 0)))
    assert x.shape == (1, 3, INPUT_SIZE[1], INPUT_SIZE[0])
    assert x[0, 0, 0, 0] == 1 and x[0, 2, 0, 0] == 0
    assert float(x[0, 1, 0, 0]) == pytest.approx(128/255)


def test_roi_excludes_foreground_and_metrics_are_not_background_accuracy():
    result = mask_metrics(np.array([[.8, .9], [.8, .1]]), np.array([[1, 0], [0, 1]]),
                          np.array([[1, 0], [1, 1]]), .25)
    assert result['truePositivePixels'] == 1 and result['falsePositivePixels'] == 1
    assert result['falseNegativePixels'] == 1 and result['foregroundIoU'] == pytest.approx(1/3)
    assert result['foregroundDice'] == .5
    with pytest.raises(ValueError, match='shape_mismatch'):
        mask_metrics(np.zeros((2, 2)), np.zeros((1, 2)), np.ones((2, 2)), .25)


def test_unverified_checkpoint_is_rejected_without_unpickling(tmp_path):
    path = tmp_path/'fake.pt'; path.write_bytes(b'not a checkpoint')
    with pytest.raises(ValueError, match='wrong_size'):
        load_verified_model(path)


def test_optional_real_weights_and_public_example():
    folder = Path(__file__).resolve().parents[1]/'models/research/pore-net'/REVISION
    path = folder/'model_checkpoints/PoreNet.pt'
    if not path.exists(): pytest.skip('Optional reviewed public checkpoint not downloaded')
    model = load_verified_model(path)
    image = Image.open(folder/'data_examples/input_cropped/20190315_144533_white.png')
    torch.set_num_threads(3)
    with torch.inference_mode(): output = model(image_tensor(image)).numpy()[0, 0]
    assert output.shape == (1280, 1024) and np.isfinite(output).all()
    gt = np.asarray(Image.open(folder/'data_examples/label_cropped/20190315_144533_white.png').convert('L').resize(INPUT_SIZE, Image.Resampling.BILINEAR)) > 0
    roi = np.asarray(Image.open(folder/'data_examples/mask_cropped/20190315_144533_white.png').convert('L').resize(INPUT_SIZE, Image.Resampling.BILINEAR)) > 0
    metrics = mask_metrics(output, gt, roi, .25)
    # This is a fixed author example regression check, not a held-out benchmark.
    assert metrics['foregroundIoU'] == pytest.approx(.4298969522, abs=1e-5)
    assert metrics['foregroundDice'] == pytest.approx(.6012978090, abs=1e-5)
