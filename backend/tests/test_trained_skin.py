from __future__ import annotations
import hashlib
import json
import os
from pathlib import Path
import time

import pytest
from fastapi.testclient import TestClient
from PIL import Image

from ruyuan.app import create_app
from ruyuan.analyzer import analyze, Cancelled
from ruyuan.config import Settings
from ruyuan.schemas import AnalysisReport
from ruyuan.trained_skin import MODEL_SPECS, availability, augment_report, classify, verify_artifact

ROOT=Path(__file__).resolve().parents[2]
MODEL_ROOT=ROOT/'backend/models/skin'
REFERENCE=Path(os.environ.get('RUYUAN_REAL_MODEL_IMAGE',str(ROOT/'.build/reference-video/0012.jpg')))
TOKEN='synthetic-local-model-test-'+ 'x'*40


def report_fixture():
    return {'id':'','createdAt':'2026-11-12T00:00:00Z','origin':'server','status':'partial','imageFileName':'synthetic.jpg',
            'imageWidth':324,'imageHeight':720,'geometry':[],
            'skin':[{'dimension':d,'score':None,'status':'baseline','items':[]} for d in ['waterOil','tone','sensitivity','smoothness','aging']],
            'landmarks':[],'overlays':[],'quality':[],'modelVersion':'synthetic','summary':'test'}


def test_unconfigured_models_explicitly_disabled():
    states=availability(None)
    assert len(states)==3
    assert all(s['state']=='disabled' and not s['spatialOutput'] for s in states)
    assert all(s['confidenceMeaning']=='softmax_not_accuracy' for s in states)


def test_missing_models_are_not_downloaded_or_inferred(tmp_path):
    assert all(s['state']=='not_downloaded' for s in availability(tmp_path))
    result=classify(Image.new('RGB',(224,224)),tmp_path)
    assert all(r['state']=='not_downloaded' and 'label' not in r for r in result)
    assert list(tmp_path.iterdir())==[]


def test_digest_validation_rejects_tampered_content(tmp_path):
    p=tmp_path/'model.safetensors';p.write_bytes(b'original')
    record={'bytes':8,'sha256':hashlib.sha256(b'original').hexdigest()}
    assert verify_artifact(p,record)
    p.write_bytes(b'modified')
    assert not verify_artifact(p,record)


def test_metadata_git_blob_digest_is_checked(tmp_path):
    p=tmp_path/'config.json';data=b'{}';p.write_bytes(data)
    record={'bytes':2,'sha256':None,'git_blob_sha1':hashlib.sha1(b'blob 2\0'+data).hexdigest()}
    assert verify_artifact(p,record)
    p.write_bytes(b'[]')
    assert not verify_artifact(p,record)


def test_optional_failure_keeps_nil_scores_and_no_fake_mask(tmp_path):
    report=augment_report(report_fixture(),availability(tmp_path))
    assert all(m['score'] is None for m in report['skin'])
    assert report['overlays']==[]
    assert sum(i['valueText'].startswith('未运行') for m in report['skin'] for i in m['items'])==3
    AnalysisReport.model_validate(report)


def test_cancel_callback_propagates_without_inference():
    def cancel(_):raise Cancelled('cancelled')
    with pytest.raises(Cancelled):classify(Image.new('RGB',(224,224)),None,progress=cancel)


def test_model_status_endpoint_requires_current_token(tmp_path):
    with TestClient(create_app(Settings(TOKEN,tmp_path/'private'),run_workers=False)) as client:
        assert client.get('/v1/models').status_code==401
        response=client.get('/v1/models',headers={'Authorization':f'Bearer {TOKEN}'})
        assert response.status_code==200
        data=response.json()
        assert data['automaticDownloads'] is False
        assert all(m['state']=='disabled' for m in data['models'])
        assert str(tmp_path) not in response.text


def test_required_models_flag_is_explicit_opt_in(tmp_path,monkeypatch):
    monkeypatch.setenv('RUYUAN_API_TOKEN',TOKEN)
    monkeypatch.setenv('RUYUAN_DATA_DIR',str(tmp_path))
    monkeypatch.delenv('RUYUAN_SKIN_MODELS_DIR',raising=False)
    monkeypatch.delenv('RUYUAN_SKIN_MODELS_REQUIRED',raising=False)
    settings=Settings.from_env()
    assert settings.skin_models_dir is None and not settings.skin_models_required
    monkeypatch.setenv('RUYUAN_SKIN_MODELS_DIR',str(tmp_path/'models'))
    monkeypatch.setenv('RUYUAN_SKIN_MODELS_REQUIRED','1')
    settings=Settings.from_env()
    assert settings.skin_models_required and settings.skin_models_dir==tmp_path/'models'

REAL_ENABLED=os.environ.get('RUYUAN_RUN_REAL_MODELS')=='1' and REFERENCE.is_file()
real=pytest.mark.skipif(not REAL_ENABLED,reason='explicit local trained-model/image run required')


@real
def test_real_classifiers_have_verified_versions_and_reproducible_outputs():
    image=Image.open(REFERENCE).convert('RGB').crop((42,130,282,470))
    first=classify(image,MODEL_ROOT)
    second=classify(image,MODEL_ROOT)
    assert len(first)==3 and all(o['state']=='ready' and 'label' in o for o in first)
    for one,two in zip(first,second):
        assert one['revision']==MODEL_SPECS[one['id']]['revision']
        assert one['inputSHA256']==two['inputSHA256']
        assert one['confidence']==pytest.approx(two['confidence'],abs=1e-7)
        assert sum(p['probability'] for p in one['probabilities'])==pytest.approx(1.0,abs=1e-6)
    acne=next(o for o in first if o['id']=='acne')
    assert {p['label'] for p in acne['probabilities']}=={'level -1','level 0','level 1','level 2','level 3'}


@real
def test_real_pipeline_cancellation_during_model_stage(tmp_path):
    settings=Settings(TOKEN,tmp_path,face_model=ROOT/'backend/models/face_landmarker.task',skin_models_dir=MODEL_ROOT)
    def progress(stage,value):
        if stage=='skin_models' and value>=0.70:raise Cancelled('cancelled')
    with pytest.raises(Cancelled):analyze(REFERENCE,settings,progress)


@real
def test_real_face_detection_classifiers_and_authenticated_api(tmp_path):
    settings=Settings(TOKEN,tmp_path/'private',face_model=ROOT/'backend/models/face_landmarker.task',
                      skin_models_dir=MODEL_ROOT,skin_models_required=True)
    headers={'Authorization':f'Bearer {TOKEN}','Idempotency-Key':'real-model-pipeline-test'}
    with TestClient(create_app(settings),headers=headers) as client:
        upload=client.post('/v1/uploads',files={'file':('reference.jpg',REFERENCE.read_bytes(),'image/jpeg')})
        assert upload.status_code==201,upload.text
        asset=upload.json()['assetId']
        consent=client.post('/v1/consents',json={'purpose':'skin_appearance_analysis','version':'1.0'}).json()['consentId']
        job=client.post('/v1/analyses',json={'assetId':asset,'consentId':consent,'idempotencyKey':'real-model-pipeline-test'})
        assert job.status_code==202,job.text
        job_id=job.json()['id'];deadline=time.monotonic()+45
        while time.monotonic()<deadline:
            state=client.get('/v1/analyses/'+job_id).json()
            if state['status'] in {'completed','failed'}:break
            time.sleep(0.1)
        assert state['status']=='completed',state
        report_id=state['reportId']
        response=client.get('/v1/reports/'+report_id)
        assert response.status_code==200,response.text
        report=response.json();AnalysisReport.model_validate(report)
        trained=[i for m in report['skin'] for i in m['items'] if i['id'] in {'trained-acne','trained-wrinkles','trained-skin_type'}]
        assert len(trained)==3 and all('模型置信度' in i['valueText'] for i in trained)
        assert all(m['score'] is None for m in report['skin'])
        assert not any(o['id'].startswith('trained-') for o in report['overlays'])
        assert client.get('/v1/reports/'+report_id,headers={'Authorization':'Bearer '+ 'wrong-token-'+ 'z'*40}).status_code==401
        assert client.delete('/v1/analyses/'+job_id).status_code==204
        assert client.get('/v1/reports/'+report_id).status_code==404
