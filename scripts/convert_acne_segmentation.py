#!/usr/bin/env python3
"""Convert hash-pinned public Acnes tensor weights and verify actual Core ML pixels.

Author notebook is provenance data, never executed. All fixtures are an author's
public example or deterministic synthetic RGB; no user photograph enters CI.
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
import urllib.parse
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'backend'))
SOURCE = ROOT/'docs/models/acne-segmentation-source.json'
MAX_PROBABILITY_ERROR = .001
MAX_MASK_DISAGREEMENT = .001
PRECISION = 'float32_activations_float16_weights'


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for data in iter(lambda: stream.read(1024*1024), b''): result.update(data)
    return result.hexdigest()


def parity_failure(output, receipt, message):
    """Keep collected numerical evidence when a conversion gate rejects output."""
    receipt['state'] = 'parity_failed'
    receipt['validation']['failure'] = message
    (output/'AcneSegmentation-resource-manifest.json').write_text(
        json.dumps(receipt,indent=2)+'\n',encoding='utf-8')
    raise ValueError(message)


def checked_sources(folder, download):
    source = json.loads(SOURCE.read_text(encoding='utf-8'))
    if source['revision'] != '79182ede8d14cb44de63b4f6ace1fa2a5a7a3d83':
        raise ValueError('unreviewed_acne_source_revision')
    for record in source['files']:
        relative = Path(record['path'])
        if relative.is_absolute() or '..' in relative.parts or len(relative.parts) != 1:
            raise ValueError('unsafe_acne_source_path')
        path = folder/relative
        if not path.exists() and download:
            errors = []
            for url in [record['source']] + record.get('mirrors', []):
                parsed = urllib.parse.urlsplit(url)
                if parsed.scheme != 'https' or parsed.hostname not in ('huggingface.co', 'raw.githubusercontent.com', 'hf-mirror.com'):
                    raise ValueError('unapproved_acne_source_host')
                temporary = path.with_suffix(path.suffix+'.download')
                try:
                    request = urllib.request.Request(url, headers={'User-Agent':'Ruyuan-Verified-Acne-Conversion'})
                    with urllib.request.urlopen(request, timeout=120) as response, temporary.open('wb') as output:
                        count = 0
                        while data := response.read(1024*1024):
                            count += len(data)
                            if count > record['bytes']: raise ValueError('acne_source_byte_budget_exceeded')
                            output.write(data)
                    if temporary.stat().st_size != record['bytes'] or digest(temporary) != record['sha256']:
                        raise ValueError('acne_source_download_hash_mismatch')
                    temporary.replace(path)
                    break
                except Exception as error:
                    errors.append(type(error).__name__)
            if not path.is_file(): raise ValueError('pinned_acne_source_download_failed:'+record['path']+':'+','.join(errors))
        if not path.is_file() or path.stat().st_size != record['bytes'] or digest(path) != record['sha256']:
            raise ValueError('acne_source_missing_or_digest_mismatch:'+record['path'])
    return source


def run(folder, output, download=False, preflight=False):
    import numpy as np
    from PIL import Image
    import torch
    from ruyuan.acne_segmentation import load_verified_model, image_tensor, MEAN, STD, THRESHOLD, PARAMETER_COUNT
    folder.mkdir(parents=True, exist_ok=True)
    source = checked_sources(folder, download)
    torch.set_num_threads(3)
    model = load_verified_model(folder/'Acnes_model.pth')
    rng = np.random.default_rng(20261112)
    fixtures = [('author_public_example', Image.open(folder/'original.jpg').convert('RGB')),
                ('uniform_skin_rgb', Image.new('RGB', (256, 256), (182,137,111))),
                ('uniform_dark_rgb', Image.new('RGB', (256,256), (60,43,35))),
                ('uniform_light_rgb', Image.new('RGB', (256,256), (232,211,195))),
                ('seeded_rgb_noise', Image.fromarray(rng.integers(0,256,size=(256,256,3),dtype=np.uint8), 'RGB'))]
    expected = []
    with torch.inference_mode():
        for name, image in fixtures:
            tensor = image_tensor(image)
            # Feed exact OpenCV-resized RGB uint8 to ImageType, not a different PIL resize.
            rgb = np.rint(tensor.numpy()[0].transpose(1,2,0)*255).astype(np.uint8)
            frame = Image.fromarray(rgb, 'RGB')
            probability = model(tensor).cpu().numpy()
            if probability.shape != (1,1,256,256) or not np.isfinite(probability).all():
                raise ValueError('acne_source_runtime_shape_or_probability_failed')
            expected.append((name, frame, tensor, probability))
        traced = torch.jit.trace(model, expected[0][2], check_trace=True, strict=True)
        trace_error = max(float(np.max(np.abs(traced(tensor).cpu().numpy()-probability)))
                          for _, _, tensor, probability in expected)
    if trace_error > 1e-6: raise ValueError('acne_torch_trace_parity_failed')
    reference = expected[1][3][0,0]
    probe_positions = [(0,0),(128,0),(255,0),(0,128),(128,128),(255,128),(0,255),(128,255),(255,255)]
    fixture_reference = {'schema':1,'revision':source['revision'],
                         'sourceSHA256':next(f['sha256'] for f in source['files'] if f['path']=='Acnes_model.pth'),
                         'input':{'width':256,'height':256,'colorRGB':[182,137,111]},
                         'probes':[{'x':x,'y':y,'probability':float(reference[y,x])} for x,y in probe_positions],
                         'thresholdCounts':[{'threshold':t,'candidatePixels':int((reference>t).sum())} for t in (.2,.5)],
                         'meaning':'Fixed original-weight PyTorch fixture; no skin accuracy or clinical meaning.'}
    receipt = {'schema':1,'id':'acne_segmentation','state':'torch_preflight_only' if preflight else 'converting',
               'source':source,'computePrecision':PRECISION,'modelType':'neuralNetwork','parameterCount':PARAMETER_COUNT,
               'input':{'name':'image','kind':'ImageType','width':256,'height':256,'colorLayout':'RGB',
                        'scale':1/255,'bias':[0,0,0],'embeddedNormalization':{'mean':MEAN,'std':STD},
                        'sourceResize':'OpenCV INTER_LINEAR uint8; Core ML parity receives exactly resized RGB'},
               'output':{'name':'acneProbability','kind':'MultiArray','dtype':'float32','shape':[1,1,256,256]},
               'threshold':THRESHOLD,'validation':{'data':'one author public image with no GT plus four synthetic RGB fixtures',
                   'traceMaxAbsoluteProbabilityError':trace_error,'samples':[],
                   'gates':{'maxAbsoluteProbabilityError':MAX_PROBABILITY_ERROR,
                            'maxMaskDisagreementFraction':MAX_MASK_DISAGREEMENT,'exactOutputShape':[1,1,256,256]}},
               'environment':{'system':platform.system(),'machine':platform.machine(),'python':platform.python_version(),
                   'packages':{p:importlib.metadata.version(p) for p in ('torch','numpy','Pillow','segmentation-models-pytorch','timm','torchvision')}}}
    output.mkdir(parents=True, exist_ok=True)
    (output/'AcneSegmentation-fixture-reference.json').write_text(json.dumps(fixture_reference,indent=2)+'\n',encoding='utf-8')
    if preflight: return receipt
    import coremltools as ct
    from coremltools.models.neural_network.quantization_utils import quantize_weights
    if ct.__version__ != '9.0' or torch.__version__.split('+')[0] != '2.7.0':
        raise ValueError('use_acne_hash_locked_mac_conversion_environment')
    started = time.perf_counter()
    converted = ct.convert(traced, source='pytorch', convert_to='neuralnetwork',
                           minimum_deployment_target=ct.target.iOS14, compute_units=ct.ComputeUnit.CPU_ONLY,
                           inputs=[ct.ImageType(name='image',shape=(1,3,256,256),scale=1/255,
                                                bias=[0,0,0],color_layout=ct.colorlayout.RGB)],
                           outputs=[ct.TensorType(name='acneProbability',dtype=np.float32)])
    converted = quantize_weights(converted, nbits=16)
    converted.author = 'Rihem Bessalah; Ruyuan verified conversion'
    converted.license = 'Apache-2.0; full training-image provenance not supplied by author'
    converted.short_description = 'Binary acne-related pixel candidates; not acne subtype, lesion count or skin-health score.'
    converted.version = source['revision'][:12]
    for key,value in {'repository':source['repository'],'revision':source['revision'],
                      'source_sha256':fixture_reference['sourceSHA256'],'compute_precision':PRECISION,
                      'normalization':json.dumps({'mean':MEAN,'std':STD}),'threshold':str(THRESHOLD)}.items():
        converted.user_defined_metadata['ruyuan.'+key] = value
    path = output/'AcneSegmentation.mlmodel'
    if path.exists(): raise ValueError('acne_output_model_already_exists')
    converted.save(str(path))
    delivered = ct.models.MLModel(str(path), compute_units=ct.ComputeUnit.CPU_ONLY)
    for name,frame,_,original in expected:
        actual = np.asarray(delivered.predict({'image':frame})['acneProbability'],dtype=np.float32)
        if actual.shape != (1,1,256,256) or not np.isfinite(actual).all() or actual.min()<0 or actual.max()>1:
            receipt['validation']['invalidRuntimeOutput'] = {'name':name,'shape':list(actual.shape),
                'finitePixels':int(np.isfinite(actual).sum()),'totalPixels':int(actual.size)}
            parity_failure(output,receipt,'acne_coreml_runtime_shape_or_probability_failed')
        error = np.abs(actual-original)
        sample = {'name':name,'shape':list(actual.shape),'maxAbsoluteProbabilityError':float(error.max()),
                  'meanAbsoluteProbabilityError':float(error.mean()),'thresholds':[]}
        receipt['validation']['samples'].append(sample)
        for threshold in (.2,.5):
            fraction = float(np.mean((actual>threshold)!=(original>threshold)))
            sample['thresholds'].append({'threshold':threshold,'maskDisagreementFraction':fraction,
                                        'torchCandidatePixels':int((original>threshold).sum()),
                                        'coremlCandidatePixels':int((actual>threshold).sum())})
            if fraction > MAX_MASK_DISAGREEMENT:
                parity_failure(output,receipt,'acne_coreml_threshold_mask_parity_failed')
        if float(error.max()) > MAX_PROBABILITY_ERROR:
            parity_failure(output,receipt,'acne_coreml_pixel_probability_parity_failed')
    receipt['state'] = 'converted_and_coreml_cpu_verified'
    receipt['validation']['meaning'] = 'CPU format-conversion parity only; no independent selfie accuracy or IoU claim'
    receipt['conversionAndVerificationSeconds'] = round(time.perf_counter()-started,3)
    receipt['environment']['packages']['coremltools'] = ct.__version__
    receipt['resource'] = {'fileName':path.name,'bytes':path.stat().st_size,'sha256':digest(path),
                           'inputName':'image','outputName':'acneProbability','outputShape':[1,1,256,256],
                           'revision':source['revision'],'computePrecision':PRECISION,'threshold':THRESHOLD}
    (output/'LICENSE-AcneSegmentation.txt').write_bytes((folder/'LICENSE').read_bytes())
    (output/'AcneSegmentation-resource-manifest.json').write_text(json.dumps(receipt,indent=2)+'\n',encoding='utf-8')
    with zipfile.ZipFile(output/'Ruyuan-AcneSegmentation.zip','w',compression=zipfile.ZIP_STORED) as archive:
        for name in ('AcneSegmentation.mlmodel','AcneSegmentation-resource-manifest.json',
                     'AcneSegmentation-fixture-reference.json','LICENSE-AcneSegmentation.txt'):
            archive.write(output/name,name)
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--models-root',type=Path,default=ROOT/'backend/models/research/acne-segmentation')
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--download',action='store_true')
    parser.add_argument('--preflight',action='store_true')
    args = parser.parse_args()
    if not args.preflight and sys.platform!='darwin': parser.error('Actual Core ML CPU verification requires macOS; preflight is Torch only.')
    args.output.mkdir(parents=True,exist_ok=True)
    try:
        result = run(args.models_root,args.output,args.download,args.preflight)
        name = 'AcneSegmentation-preflight.json' if args.preflight else 'AcneSegmentation-resource-manifest.json'
        (args.output/name).write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
        print(json.dumps({'state':result['state'],'resource':result.get('resource'),'validation':result['validation']},separators=(',',':')),flush=True)
    except Exception as error:
        (args.output/'conversion-failed.json').write_text(json.dumps({'errorType':type(error).__name__,'message':str(error)},indent=2)+'\n',encoding='utf-8')
        raise


if __name__=='__main__': main()
