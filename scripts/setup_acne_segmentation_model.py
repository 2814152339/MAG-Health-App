#!/usr/bin/env python3
"""Verify the exact public Acnes model actually converted and CPU-tested on macOS."""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FOLDER = ROOT/'iOS/Ruyuan/Resources/Models'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--check', action='store_true')
parser.parse_args()
manifest = json.loads((FOLDER/'AcneSegmentation-resource-manifest.json').read_text(encoding='utf-8'))
resource = manifest['resource']
assert manifest['schema']==1 and manifest['id']=='acne_segmentation'
assert manifest['state']=='converted_and_coreml_cpu_verified'
assert resource['fileName']=='AcneSegmentation.mlmodel'
assert resource['bytes']==48_862_307
assert resource['sha256']=='0d022cbf4e3f266128ff23525a683452a43f05079d88eba4fd6f4124f40daf7a'
assert resource['outputShape']==[1,1,256,256]
assert resource['revision']=='79182ede8d14cb44de63b4f6ace1fa2a5a7a3d83'
assert resource['computePrecision']=='float32_activations_float16_weights'
assert manifest['validation']['gates']=={
    'maxAbsoluteProbabilityError':.001,'maxMaskDisagreementFraction':.001,'exactOutputShape':[1,1,256,256]}
samples=manifest['validation']['samples']
assert len(samples)==5 and {s['name'] for s in samples}=={
    'author_public_example','uniform_skin_rgb','uniform_dark_rgb','uniform_light_rgb','seeded_rgb_noise'}
for sample in samples:
    assert sample['shape']==[1,1,256,256]
    assert 0<=sample['meanAbsoluteProbabilityError']<=sample['maxAbsoluteProbabilityError']<=.001
    assert len(sample['thresholds'])==2 and {r['threshold'] for r in sample['thresholds']}=={.2,.5}
    assert all(0<=r['maskDisagreementFraction']<=.001 for r in sample['thresholds'])
model=FOLDER/resource['fileName']
assert model.stat().st_size==resource['bytes'] and hashlib.sha256(model.read_bytes()).hexdigest()==resource['sha256']
assert hashlib.sha256((FOLDER/'LICENSE-AcneSegmentation.txt').read_bytes()).hexdigest()=='c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4'
fixture=json.loads((FOLDER/'AcneSegmentation-fixture-reference.json').read_text(encoding='utf-8'))
assert fixture['revision']==resource['revision']
assert fixture['sourceSHA256']=='c58a6af6fb622d916e4aa788d9f620d59df4a42209f655ce4a9db49686c05697'
assert fixture['input']=={'width':256,'height':256,'colorRGB':[182,137,111]}
assert len(fixture['probes'])==9 and all(0<=p['probability']<=1 for p in fixture['probes'])
print('Verified actual Acnes Core ML model:',resource['bytes'],'bytes; SHA256',resource['sha256'])
