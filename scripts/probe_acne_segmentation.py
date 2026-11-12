#!/usr/bin/env python3
"""Reproduce the reviewed binary acne candidate model on public/synthetic inputs.

Downloads only hash-pinned weights, notices and the author's public sample.
Never executes downloaded Python/notebooks, never unpickles a full model, never
uploads a photo. The default input/output directories are ignored build data.
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
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'backend'))
SOURCE = ROOT/'docs/models/acne-segmentation-source.json'
DEFAULT_FOLDER = ROOT/'.build/model-research/acnes-seg'


def file_digest(path: Path) -> str:
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for part in iter(lambda: stream.read(1024*1024), b''):
            result.update(part)
    return result.hexdigest()


def verified_sources(folder: Path, *, download: bool) -> dict:
    manifest = json.loads(SOURCE.read_text(encoding='utf-8'))
    if manifest.get('schema') != 1 or manifest.get('id') != 'rihem_acne_segmentation':
        raise ValueError('invalid_source_manifest')
    for item in manifest['files']:
        relative = Path(item['path'])
        if relative.is_absolute() or '..' in relative.parts or len(relative.parts) != 1:
            raise ValueError('unsafe_source_filename')
        target = folder/relative
        if target.is_file() and target.stat().st_size == item['bytes'] and file_digest(target) == item['sha256']:
            continue
        if not download:
            raise ValueError('source_missing_or_hash_mismatch:'+item['path'])
        target.parent.mkdir(parents=True, exist_ok=True)
        temporary = target.with_suffix(target.suffix+'.download')
        failure = None
        # Explicit mirror only for the identical SHA-pinned HF state_dict.
        for url in [item['source']] + item.get('mirrors', []):
            if not url.startswith(('https://huggingface.co/', 'https://hf-mirror.com/',
                                   'https://raw.githubusercontent.com/')):
                raise ValueError('unapproved_pinned_source_host')
            try:
                request = urllib.request.Request(url, headers={'User-Agent':'Ruyuan-Public-Acne-Model-Probe/1.0'})
                with urllib.request.urlopen(request, timeout=40) as response, temporary.open('wb') as output:
                    count = 0
                    while part := response.read(1024*1024):
                        count += len(part)
                        if count > item['bytes']:
                            raise ValueError('source_exceeds_pinned_size')
                        output.write(part)
                if temporary.stat().st_size != item['bytes'] or file_digest(temporary) != item['sha256']:
                    raise ValueError('downloaded_source_digest_mismatch')
                temporary.replace(target)
                break
            except (OSError, ValueError, urllib.error.URLError) as error:
                # Partial bytes never become verified sources. No unsafe fallback.
                temporary.unlink(missing_ok=True)
                failure = type(error).__name__
        else:
            raise ValueError('source_download_failed:'+item['path']+':'+str(failure))
    return manifest


def run(folder: Path, output: Path, *, download: bool) -> dict:
    import cv2
    import numpy as np
    from PIL import Image
    import torch
    from ruyuan.acne_segmentation import (
        AcneSegmentationService, INPUT_SIZE, MEAN, PARAMETER_COUNT, STD, THRESHOLD,
    )
    source = verified_sources(folder, download=download)
    output.mkdir(parents=True, exist_ok=True)
    torch.set_num_threads(3)
    service = AcneSegmentationService(folder/'Acnes_model.pth')
    service.load()
    rng = np.random.default_rng(20261112)
    fixtures = [
        ('author_public_example', Image.open(folder/'original.jpg').convert('RGB')),
        ('uniform_rgb', Image.new('RGB', INPUT_SIZE, (182, 137, 111))),
        ('seeded_rgb_noise', Image.fromarray(rng.integers(0, 256, size=(256, 256, 3), dtype=np.uint8))),
    ]
    receipt = {
        'schema':1, 'id':source['id'], 'state':'local_pytorch_verified_not_coreml',
        'source':source, 'parameterCount':PARAMETER_COUNT,
        'input':{'width':256, 'height':256, 'layout':'RGB', 'resize':'OpenCV INTER_LINEAR stretched uint8',
                 'scale':1/255, 'embeddedMean':MEAN, 'embeddedStd':STD},
        'output':{'name':'acneProbability', 'dtype':'float32', 'shape':[1, 1, 256, 256]},
        'threshold':THRESHOLD, 'thresholdComparison':'>',
        'validationData':'One fixed author-public photo plus two deterministic synthetic inputs; no private photos',
        'groundTruth':'Not supplied for the author sample; IoU/Dice/accuracy not measured',
        'environment':{'python':platform.python_version(), 'system':platform.system(),
                       'machine':platform.machine(), 'packages':{
                           key:importlib.metadata.version(key)
                           for key in ('torch','torchvision','segmentation-models-pytorch','timm','numpy','Pillow')},
                       'opencv':cv2.__version__}, 'samples':[],
    }
    for name, image in fixtures:
        started = time.perf_counter()
        result = service.analyze(image)
        raw = result.probability
        image_path, mask_path = output/(name+'-probability.png'), output/(name+'-candidates.png')
        Image.fromarray(np.rint(raw*65535).astype(np.uint16)).save(image_path)
        Image.fromarray(result.candidates.astype(np.uint8)*255).save(mask_path)
        sample = {'name':name, 'originalSize':[image.width,image.height],
                  'observation':result.observation(), 'totalSeconds':time.perf_counter()-started,
                  'probabilitySumFloat64':float(raw.astype(np.float64).sum()),
                  'probes':[{'x':x,'y':y,'probability':float(raw[y,x])}
                            for y in (0,128,255) for x in (0,128,255)],
                  'probabilityPNG_SHA256':file_digest(image_path),
                  'candidatePNG_SHA256':file_digest(mask_path)}
        receipt['samples'].append(sample)
        print(name+': '+json.dumps(sample['observation'],ensure_ascii=False),flush=True)
    (output/'acne-segmentation-pytorch-receipt.json').write_text(
        json.dumps(receipt,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    return receipt


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-dir',type=Path,default=DEFAULT_FOLDER)
    parser.add_argument('--output',type=Path,default=ROOT/'.build/acne-segmentation-verification')
    parser.add_argument('--download',action='store_true')
    args = parser.parse_args()
    run(args.source_dir.resolve(),args.output.resolve(),download=args.download)


if __name__ == '__main__':
    main()
