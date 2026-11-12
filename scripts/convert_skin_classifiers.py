#!/usr/bin/env python3
"""Convert reviewed local ViT checkpoints to iOS17 RGB-image Core ML packages.

macOS is required for the actual Core ML prediction parity gate. CI uses only
synthetic RGB fixtures and never receives private photographs. --preflight can
validate source files and Torch preprocessing/tracing on Windows, but is NOT a
Core ML conversion success.
"""
from __future__ import annotations
import argparse
import gc
import hashlib
import importlib.metadata
import json
from pathlib import Path
import platform
import sys
import time
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE_MANIFEST = ROOT/'backend/ruyuan/skin_model_manifest.json'
NAMES = {'acne':'RuyuanAcneFloat16','wrinkles':'RuyuanWrinklesFloat16','skin_type':'RuyuanSkinTypeFloat32'}
# The skin-type checkpoint has a verified near-tie on seeded_noise: PyTorch's
# normal-vs-dry logit margin is 0.0010882076. FLOAT16 flipped that ranking on the
# actual macOS CPU runtime (run 43132528504). Preserve source decisions by keeping
# this checkpoint in FLOAT32, rather than relaxing the all-Top1-match gate.
PRECISIONS = {'acne':'float16','wrinkles':'float16','skin_type':'float32'}
EXPECTED = {'coremltools':'9.0','torch':'2.7.0','transformers':'4.57.6','safetensors':'0.7.0','numpy':'1.26.4','Pillow':'11.3.0'}


def sha256(path: Path) -> str:
    digest=hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda:stream.read(1024*1024),b''):digest.update(chunk)
    return digest.hexdigest()


def verify_source(path: Path, record: dict) -> None:
    if not path.is_file() or path.stat().st_size != record['bytes']:
        raise ValueError('missing_or_wrong_size:'+record['name'])
    if record.get('sha256'):
        valid=sha256(path)==record['sha256']
    else:
        blob=hashlib.sha1(f"blob {record['bytes']}\0".encode()+path.read_bytes()).hexdigest()
        valid=blob==record['git_blob_sha1']
    if not valid:raise ValueError('source_digest_mismatch:'+record['name'])


def environment() -> dict:
    versions={}
    for name in EXPECTED:
        try:versions[name]=importlib.metadata.version(name)
        except importlib.metadata.PackageNotFoundError:versions[name]='not_installed'
    return {'system':platform.system(),'machine':platform.machine(),'macOS':platform.mac_ver()[0],
            'python':platform.python_version(),'packages':versions}


def synthetic_images():
    import numpy as np
    from PIL import Image
    x,y=np.meshgrid(np.arange(224),np.arange(224))
    fixtures={
        'uniform_rgb':np.full((224,224,3),(182,137,111),dtype=np.uint8),
        'rgb_coordinate_ramp':np.stack((x*255//223,y*255//223,(x+y)*255//446),axis=2).astype(np.uint8),
        'seeded_noise':np.random.default_rng(20261112).integers(0,256,size=(224,224,3),dtype=np.uint8),
        'checkerboard':np.repeat((((x//16+y//16)%2)*200+25)[...,None],3,axis=2).astype(np.uint8),
        'channel_stripes':np.stack(((x%37)*7,(y%37)*7,((x+y)%37)*7),axis=2).clip(0,255).astype(np.uint8),
    }
    return [(name,Image.fromarray(array,'RGB')) for name,array in fixtures.items()]


def package_files(folder: Path) -> list[dict]:
    return [{'path':path.relative_to(folder).as_posix(),'bytes':path.stat().st_size,'sha256':sha256(path)}
            for path in sorted(folder.rglob('*')) if path.is_file()]


def convert_one(key: str, models_root: Path, output: Path, *, preflight: bool=False) -> dict:
    import numpy as np
    import torch
    from transformers import ViTForImageClassification, ViTImageProcessor
    spec=next(m for m in json.loads(SOURCE_MANIFEST.read_text(encoding='utf-8'))['models'] if m['id']==key)
    folder=models_root/key/spec['revision']
    for record in spec['files']:verify_source(folder/record['name'],record)
    processor_config=json.loads((folder/'preprocessor_config.json').read_text())
    config=json.loads((folder/'config.json').read_text())
    if config.get('architectures') != ['ViTForImageClassification'] or config.get('model_type') != 'vit':
        raise ValueError('unsupported_architecture')
    if processor_config.get('size') != {'height':224,'width':224}:
        raise ValueError('unsupported_image_size')
    means=processor_config['image_mean'];stds=processor_config['image_std']
    if not processor_config.get('do_normalize') or not processor_config.get('do_rescale') or len(set(stds)) != 1:
        raise ValueError('preprocessor_requires_unsupported_channel_specific_scale')
    # Core ML ImageType uses y = x*scale+bias. These checkpoints all have std=.5,
    # so a single exact scale works: 2/255 and per-channel bias=-1.
    scale=float(processor_config['rescale_factor'])/float(stds[0])
    bias=[-float(m)/float(s) for m,s in zip(means,stds)]
    labels=[config['id2label'][str(i)] for i in range(len(config['id2label']))]
    processor=ViTImageProcessor.from_pretrained(str(folder),local_files_only=True)
    net=ViTForImageClassification.from_pretrained(str(folder),local_files_only=True,use_safetensors=True,attn_implementation='eager')
    net.eval();net.to('cpu')
    torch.set_num_threads(3)
    torch.manual_seed(20261112)

    class LogitsOnly(torch.nn.Module):
        def __init__(self,network):super().__init__();self.network=network
        def forward(self,image):return self.network(pixel_values=image,return_dict=False)[0]

    wrapped=LogitsOnly(net).eval()
    fixtures=synthetic_images()
    torch_results=[]
    preprocess_error=0.0
    with torch.inference_mode():
        for name,image in fixtures:
            expected=processor(images=image,return_tensors='pt')['pixel_values']
            raw=np.asarray(image,dtype=np.float32).transpose(2,0,1)[None,...]
            # Match HF's two-stage float32 rescale/normalization, not rounded uint8 math.
            manual=(raw*float(processor_config['rescale_factor'])-np.asarray(means,dtype=np.float32)[None,:,None,None])/np.asarray(stds,dtype=np.float32)[None,:,None,None]
            preprocess_error=max(preprocess_error,float(np.max(np.abs(manual-expected.numpy()))))
            logits=wrapped(expected).cpu().numpy().astype(np.float64).reshape(-1)
            if logits.shape != (len(labels),) or not np.all(np.isfinite(logits)):raise ValueError('invalid_torch_output')
            torch_results.append((name,image,expected,logits))
        if preprocess_error > 1e-6:raise ValueError('preprocessing_parity_failed')
        example=torch_results[0][2]
        traced=torch.jit.trace(wrapped,example,strict=True,check_trace=True)
        trace_error=max(float(np.max(np.abs(traced(item[2]).cpu().numpy().reshape(-1)-item[3]))) for item in torch_results)
        if trace_error > 1e-5:raise ValueError('torch_trace_parity_failed')
    receipt={'schema':1,'id':key,'name':NAMES[key],'state':'preflight_only' if preflight else 'converting',
        'source':{'repository':spec['repo'],'revision':spec['revision'],'license':spec['license'],
                  'modelSHA256':next(f['sha256'] for f in spec['files'] if f['name']=='model.safetensors'),
                  'manifestSHA256':sha256(SOURCE_MANIFEST)},
        'environment':environment(),'minimumDeploymentTarget':'iOS17','computePrecision':PRECISIONS[key],
        'computePrecisionReason':('preserve source near-tie ranking; FLOAT16 failed seeded_noise Top1 in run43132528504'
                                  if key=='skin_type' else 'FLOAT16 validated against source PyTorch on five fixtures'),
        'input':{'name':'image','kind':'ImageType','colorLayout':'RGB','width':224,'height':224,
                 'scale':scale,'bias':bias,'sourceImageMean':means,'sourceImageStd':stds,
                 'resize':'caller resizes face crop to exactly224x224 using bilinear; not a full-photo detector'},
        'output':{'name':'logits','kind':'MultiArray','dtype':'float32','shape':[1,len(labels)],'classNames':labels,
                  'meaning':'raw class logits; softmax probability is confidence, not validated accuracy or clinical measurement'},
        'validation':{'data':'five deterministic synthetic224RGB images only; no private photographs',
                      'preprocessMaxAbsoluteError':preprocess_error,'traceMaxAbsoluteLogitError':trace_error,'samples':[]}}
    if preflight:
        receipt['validation']['torchPredictions']=[{'name':n,'logits':v.tolist()} for n,_,_,v in torch_results]
        return receipt

    import coremltools as ct
    started=time.perf_counter()
    mlmodel=ct.convert(traced,source='pytorch',convert_to='mlprogram',
        minimum_deployment_target=ct.target.iOS17,
        compute_precision=ct.precision.FLOAT32 if PRECISIONS[key]=='float32' else ct.precision.FLOAT16,
        compute_units=ct.ComputeUnit.CPU_ONLY,
        inputs=[ct.ImageType(name='image',shape=(1,3,224,224),scale=scale,bias=bias,color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name='logits',dtype=np.float32)])
    mlmodel.author='Original trained checkpoint: '+spec['repo']+'; Core ML format conversion: Ruyuan Aesthetics'
    mlmodel.license=spec['license']
    mlmodel.short_description='Pinned local ViT photo classification; raw logits, not a medical measurement.'
    mlmodel.version=spec['revision'][:12]
    mlmodel.input_description['image']='224x224 RGB face crop; embedded exact normalization. Face detection/cropping happens separately.'
    mlmodel.output_description['logits']='Raw logits in fixed class order. Apply stable softmax locally; confidence is not accuracy.'
    mlmodel.user_defined_metadata['ruyuan.class_names']=json.dumps(labels,separators=(',',':'))
    mlmodel.user_defined_metadata['ruyuan.repository']=spec['repo']
    mlmodel.user_defined_metadata['ruyuan.revision']=spec['revision']
    mlmodel.user_defined_metadata['ruyuan.source_sha256']=receipt['source']['modelSHA256']
    mlmodel.user_defined_metadata['ruyuan.input_scale']=repr(scale)
    mlmodel.user_defined_metadata['ruyuan.input_bias']=json.dumps(bias)
    mlmodel.user_defined_metadata['ruyuan.compute_precision']=PRECISIONS[key]
    package=output/'models'/key/(key+'.mlpackage')
    package.parent.mkdir(parents=True,exist_ok=True)
    if package.exists():raise ValueError('output_package_already_exists')
    mlmodel.save(str(package))
    # Reload the saved package so the parity gate covers the delivered artifact,
    # not just the in-memory conversion. CPU_ONLY makes hardware choice explicit.
    delivered=ct.models.MLModel(str(package),compute_units=ct.ComputeUnit.CPU_ONLY)
    actual_spec=delivered.get_spec()
    if actual_spec.description.input[0].name != 'image' or actual_spec.description.output[0].name != 'logits':
        raise ValueError('coreml_io_signature_mismatch')
    for name,image,_,expected in torch_results:
        actual=np.asarray(delivered.predict({'image':image})['logits'],dtype=np.float64).reshape(-1)
        if actual.shape != expected.shape or not np.all(np.isfinite(actual)):raise ValueError('invalid_coreml_output')
        abs_error=float(np.max(np.abs(actual-expected)))
        def softmax(x):
            exp=np.exp(x-np.max(x));return exp/np.sum(exp)
        probability_error=float(np.max(np.abs(softmax(actual)-softmax(expected))))
        top1_match=int(np.argmax(actual))==int(np.argmax(expected))
        sample={'name':name,'torchLogits':expected.tolist(),'coremlLogits':actual.tolist(),
                'maxAbsoluteLogitError':abs_error,'maxAbsoluteProbabilityError':probability_error,
                'top1Matches':top1_match,'torchClass':labels[int(np.argmax(expected))],'coremlClass':labels[int(np.argmax(actual))]}
        receipt['validation']['samples'].append(sample)
        # Numerical conversion checks, NOT a statement about clinical accuracy.
        if abs_error > 0.05 or probability_error > 0.01 or not top1_match:
            receipt['state']='parity_failed'
            (output/(key+'-coreml-manifest.json')).write_text(json.dumps(receipt,indent=2)+'\n')
            raise ValueError('coreml_parity_failed:'+PRECISIONS[key]+':'+name)
    receipt['state']='converted_and_coreml_cpu_verified'
    receipt['validation']['gates']={'maxAbsoluteLogitError':0.05,'maxAbsoluteProbabilityError':0.01,'allTop1Match':True}
    receipt['conversionAndVerificationSeconds']=round(time.perf_counter()-started,3)
    receipt['files']=package_files(package)
    receipt['packageBytes']=sum(f['bytes'] for f in receipt['files'])
    # The original model card travels with each package. No input photo is exported.
    license_dir=output/'models'/key/'source-notices';license_dir.mkdir()
    (license_dir/'README.md').write_bytes((folder/'README.md').read_bytes())
    (license_dir/'source.json').write_text(json.dumps(receipt['source'],indent=2)+'\n')
    record={'id':key,'package':package.relative_to(output).as_posix(),'repository':spec['repo'],
            'revision':spec['revision'],'license':spec['license'],'modelSHA256':receipt['source']['modelSHA256'],
            'classes':labels,'inputName':'image','outputName':'logits','inputSize':224,'lowConfidenceThreshold':0.60,
            'inputScale':scale,'inputBias':bias,'computePrecision':PRECISIONS[key],'minimumDeploymentTarget':'iOS17',
            'files':[{'relativePath':(package.relative_to(output)/f['path']).as_posix(),'bytes':f['bytes'],'sha256':f['sha256']} for f in receipt['files']]}
    receipt['models']=[record]
    package_manifest=output/'model-manifest.json'
    package_manifest.write_text(json.dumps({'schema':1,'state':receipt['state'],'models':[record]},indent=2)+'\n',encoding='utf-8')
    archive=output/('Ruyuan-CoreML-'+key+'.zip')
    with zipfile.ZipFile(archive,'w',compression=zipfile.ZIP_STORED,allowZip64=True) as bundle:
        for path in sorted(package.rglob('*')):
            if path.is_file():bundle.write(path,path.relative_to(output).as_posix())
        for path in sorted(license_dir.iterdir()):bundle.write(path,path.relative_to(output).as_posix())
        bundle.write(package_manifest,'model-manifest.json')
    receipt['archive']={'name':archive.name,'bytes':archive.stat().st_size,'sha256':sha256(archive)}
    del delivered,mlmodel,traced,wrapped,net
    gc.collect()
    return receipt


def main() -> int:
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--models-root',type=Path,default=ROOT/'backend/models/skin')
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--models',nargs='+',choices=list(NAMES),default=['acne'])
    parser.add_argument('--preflight',action='store_true')
    args=parser.parse_args()
    env=environment()
    if not args.preflight:
        if sys.platform != 'darwin':parser.error('Real Core ML conversion and predict verification require macOS; use --preflight for Torch-only checks.')
        mismatches=[name for name,value in EXPECTED.items() if env['packages'][name].split('+')[0] != value]
        if mismatches:parser.error('Install the pinned conversion lock; mismatched: '+','.join(mismatches))
    args.output.mkdir(parents=True,exist_ok=True)
    try:
        for key in args.models:
            record=convert_one(key,args.models_root,args.output,preflight=args.preflight)
            suffix='-preflight.json' if args.preflight else '-coreml-manifest.json'
            (args.output/(key+suffix)).write_text(json.dumps(record,indent=2)+'\n',encoding='utf-8')
            print(json.dumps({'id':key,'state':record['state'],'packageBytes':record.get('packageBytes'),'validation':record['validation']},separators=(',',':')),flush=True)
    except Exception as error:
        # Only explicit source/shape/numerical failures or exception type are logged.
        # This command processes only synthetic pixels and public model checkpoints.
        (args.output/'conversion-failed.json').write_text(json.dumps({'state':'failed','errorType':type(error).__name__,'message':str(error),'environment':env},indent=2)+'\n')
        raise
    return 0

if __name__=='__main__':raise SystemExit(main())
