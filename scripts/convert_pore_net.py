#!/usr/bin/env python3
"""Convert the pinned 27 KB author Pore-Net to a standalone Core ML .mlmodel.

CI predicts only the author's public example and deterministic synthetic images.
The public image/GT/ROI and every source file are hash-pinned. No private photo,
commercial API, downloaded Python execution, optimizer, or training is involved.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import json
from pathlib import Path
import platform
import sys
import time
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'backend'))
SOURCE = ROOT/'docs/models/pore-net-source.json'


def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()


def checked_sources(folder: Path, *, download: bool) -> dict:
    source = json.loads(SOURCE.read_text(encoding='utf-8'))
    prefix = f"https://raw.githubusercontent.com/{source['repository']}/{source['revision']}/"
    for record in source['files']:
        relative = Path(record['path'])
        if relative.is_absolute() or '..' in relative.parts or not record['source'].startswith(prefix):
            raise ValueError('invalid_pinned_source')
        path = folder/relative
        if not path.exists() and download:
            path.parent.mkdir(parents=True, exist_ok=True)
            temporary = path.with_suffix(path.suffix+'.download')
            request = urllib.request.Request(record['source'], headers={'User-Agent':'Ruyuan-Pore-Net-Conversion'})
            with urllib.request.urlopen(request, timeout=40) as response, temporary.open('wb') as output:
                total = 0
                while chunk := response.read(1024*1024):
                    total += len(chunk)
                    if total > record['bytes']: raise ValueError('pinned_source_oversized')
                    output.write(chunk)
            temporary.replace(path)
        if not path.is_file() or path.stat().st_size != record['bytes'] or digest(path) != record['sha256']:
            raise ValueError('pinned_source_missing_or_hash_mismatch:'+record['path'])
    return source


def run(folder: Path, output: Path, *, download: bool, preflight: bool) -> dict:
    import numpy as np
    from PIL import Image
    import torch
    from ruyuan.pore_net import INPUT_SIZE, MEAN, STD, THRESHOLD, image_tensor, load_verified_model, mask_metrics
    source = checked_sources(folder, download=download)
    torch.set_num_threads(3)
    model = load_verified_model(folder/'model_checkpoints/PoreNet.pt')
    reference = folder/'data_examples/input_cropped/20190315_144533_white.png'
    image = Image.open(reference).convert('RGB').resize(INPUT_SIZE, Image.Resampling.BILINEAR)
    target = np.asarray(Image.open(folder/'data_examples/label_cropped/20190315_144533_white.png').convert('L').resize(INPUT_SIZE, Image.Resampling.BILINEAR)) > 0
    roi = np.asarray(Image.open(folder/'data_examples/mask_cropped/20190315_144533_white.png').convert('L').resize(INPUT_SIZE, Image.Resampling.BILINEAR)) > 0
    rng = np.random.default_rng(20261112)
    fixtures = [('author_public_example', image),
                ('uniform_rgb', Image.new('RGB', INPUT_SIZE, (182, 137, 111))),
                ('seeded_rgb_noise', Image.fromarray(rng.integers(0, 256, size=(1280, 1024, 3), dtype=np.uint8), 'RGB'))]
    with torch.inference_mode():
        expected = [(name, frame, image_tensor(frame), model(image_tensor(frame)).cpu().numpy()) for name, frame in fixtures]
        traced = torch.jit.trace(model, expected[0][2], check_trace=True, strict=True)
        trace_error = max(float(np.max(np.abs(traced(tensor).cpu().numpy()-prediction))) for _, _, tensor, prediction in expected)
    if trace_error > 1e-6: raise ValueError('pore_net_torch_trace_parity_failed')
    receipt = {'schema':1, 'id':'pore_net', 'state':'torch_preflight_only' if preflight else 'converting',
               'source':source, 'computePrecision':'float32', 'modelType':'neuralNetwork',
               'input':{'name':'image', 'kind':'ImageType', 'width':1024, 'height':1280, 'colorLayout':'RGB',
                        'scale':1/255, 'bias':[0, 0, 0], 'embeddedNormalization':{'mean':MEAN, 'std':STD}},
               'output':{'name':'poreProbability', 'kind':'MultiArray', 'dtype':'float32', 'shape':[1, 1, 1280, 1024]},
               'threshold':THRESHOLD, 'parameterCount':sum(p.numel() for p in model.parameters()),
               'validation':{'data':'author public example plus two deterministic synthetic images; no private photographs',
                             'traceMaxAbsoluteProbabilityError':trace_error, 'samples':[],
                             'publicExampleTorchMetrics':[mask_metrics(expected[0][3][0, 0], target, roi, t) for t in (.25, .4)]},
               'environment':{'system':platform.system(), 'machine':platform.machine(), 'macOS':platform.mac_ver()[0],
                              'python':platform.python_version(), 'packages':{key:importlib.metadata.version(key) for key in ('torch','numpy','Pillow')}}}
    if preflight: return receipt
    import coremltools as ct
    if ct.__version__ != '9.0' or torch.__version__.split('+')[0] != '2.7.0':
        raise ValueError('install_existing_hash_locked_coreml_dependencies')
    started = time.perf_counter()
    # NeuralNetwork is a single .mlmodel, no MLPackage external weight installer.
    converted = ct.convert(traced, source='pytorch', convert_to='neuralnetwork', minimum_deployment_target=ct.target.iOS14,
                           compute_units=ct.ComputeUnit.CPU_ONLY,
                           inputs=[ct.ImageType(name='image', shape=(1, 3, 1280, 1024), scale=1/255,
                                                bias=[0, 0, 0], color_layout=ct.colorlayout.RGB)],
                           outputs=[ct.TensorType(name='poreProbability', dtype=np.float32)])
    converted.author = 'Sunyong Seo et al.; Pore-Net; Ruyuan conversion with embedded author normalization'
    converted.license = 'Apache-2.0'
    converted.short_description = 'Pore probability candidates, not blackhead/disease classification; skin ROI required.'
    converted.version = source['revision'][:12]
    metadata = {'repository':source['repository'], 'revision':source['revision'], 'compute_precision':'float32',
                'source_sha256':next(f['sha256'] for f in source['files'] if f['path'].endswith('PoreNet.pt')),
                'normalization':json.dumps({'mean':MEAN, 'std':STD}), 'threshold':str(THRESHOLD)}
    for key, value in metadata.items(): converted.user_defined_metadata['ruyuan.'+key] = value
    path = output/'PoreNet.mlmodel'
    if path.exists(): raise ValueError('output_model_already_exists')
    converted.save(str(path))
    delivered = ct.models.MLModel(str(path), compute_units=ct.ComputeUnit.CPU_ONLY)
    for name, frame, _, original in expected:
        actual = np.asarray(delivered.predict({'image':frame})['poreProbability'], dtype=np.float32)
        if actual.shape != (1, 1, 1280, 1024):
            raise ValueError('pore_net_coreml_shape_mismatch:'+str(actual.shape))
        if not np.isfinite(actual).all() or actual.min() < 0 or actual.max() > 1:
            raise ValueError('pore_net_coreml_invalid_probability')
        error = np.abs(actual-original)
        sample = {'name':name, 'shape':list(actual.shape), 'maxAbsoluteProbabilityError':float(error.max()),
                  'meanAbsoluteProbabilityError':float(error.mean()), 'thresholds':[]}
        for threshold in (.25, .4):
            disagreement = float(np.mean((actual > threshold) != (original > threshold)))
            row = {'threshold':threshold, 'maskDisagreementFraction':disagreement}
            if name == 'author_public_example':
                row['torchMetrics'] = mask_metrics(original[0, 0], target, roi, threshold)
                row['coremlMetrics'] = mask_metrics(actual[0, 0], target, roi, threshold)
                delta = max(abs(row['torchMetrics'][k]-row['coremlMetrics'][k]) for k in ('foregroundIoU','foregroundDice'))
                row['maxForegroundMetricDifference'] = delta
                if delta > .001: raise ValueError('pore_net_coreml_foreground_metric_parity_failed')
            sample['thresholds'].append(row)
            if disagreement > .0001: raise ValueError('pore_net_coreml_threshold_mask_parity_failed')
        receipt['validation']['samples'].append(sample)
        if float(error.max()) > .0001: raise ValueError('pore_net_coreml_probability_parity_failed')
    receipt['state'] = 'converted_and_coreml_cpu_verified'
    receipt['validation']['gates'] = {'maxAbsoluteProbabilityError':.0001, 'maxMaskDisagreementFraction':.0001,
                                     'maxForegroundIoUOrDiceDifference':.001, 'exactOutputShape':[1, 1, 1280, 1024]}
    receipt['validation']['meaning'] = 'format conversion parity on one author example; not independent selfie accuracy validation'
    receipt['conversionAndVerificationSeconds'] = round(time.perf_counter()-started, 3)
    receipt['environment']['packages']['coremltools'] = ct.__version__
    receipt['resource'] = {'fileName':path.name, 'bytes':path.stat().st_size, 'sha256':digest(path),
                           'inputName':'image', 'outputName':'poreProbability', 'outputShape':[1, 1, 1280, 1024],
                           'revision':source['revision'], 'computePrecision':'float32', 'threshold':THRESHOLD}
    # Deliver license and exact public provenance alongside the single model.
    (output/'LICENSE-PoreNet.txt').write_bytes((folder/'LICENSE').read_bytes())
    (output/'PoreNet-source-manifest.json').write_bytes(SOURCE.read_bytes())
    (output/'PoreNet-resource-manifest.json').write_text(json.dumps(receipt, indent=2)+'\n', encoding='utf-8')
    archive = output/'Ruyuan-PoreNet.zip'
    with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_STORED) as bundle:
        for file in (path, output/'LICENSE-PoreNet.txt', output/'PoreNet-source-manifest.json', output/'PoreNet-resource-manifest.json'):
            bundle.write(file, file.name)
    receipt['archive'] = {'fileName':archive.name, 'bytes':archive.stat().st_size, 'sha256':digest(archive)}
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--models-root', type=Path, default=ROOT/'backend/models/research/pore-net')
    parser.add_argument('--download', action='store_true')
    parser.add_argument('--preflight', action='store_true')
    args = parser.parse_args()
    if not args.preflight and sys.platform != 'darwin': parser.error('Actual Core ML verification requires macOS; --preflight is Torch-only.')
    args.output.mkdir(parents=True, exist_ok=True)
    source = json.loads(SOURCE.read_text(encoding='utf-8'))
    try:
        receipt = run(args.models_root/source['revision'], args.output, download=args.download, preflight=args.preflight)
        path = args.output/('PoreNet-preflight.json' if args.preflight else 'PoreNet-resource-manifest.json')
        path.write_text(json.dumps(receipt, indent=2)+'\n', encoding='utf-8')
        print(json.dumps(receipt, separators=(',',':')), flush=True)
    except Exception as error:
        (args.output/'conversion-failed.json').write_text(json.dumps({'errorType':type(error).__name__,'message':str(error)}, indent=2)+'\n')
        raise


if __name__ == '__main__': main()
