"""Pinned local-only trained image classifiers; no skin measurement or segmentation.

The runtime never downloads, executes repository code or retains input images.
Only config/preprocessor JSON and safetensors verified against our reviewed
manifest are loaded. Confidence means softmax model confidence, not accuracy.
"""
from __future__ import annotations
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import threading
import time
from typing import Callable
from PIL import Image

MANIFEST_PATH = Path(__file__).with_name("skin_model_manifest.json")
MODEL_MANIFEST = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
MODEL_SPECS = {entry["id"]: entry for entry in MODEL_MANIFEST["models"]}
TITLES = {"skin_type":"训练模型 · 照片肤质分类", "acne":"训练模型 · 痘外观分类", "wrinkles":"训练模型 · 皱纹外观分类"}
DIMENSIONS = {"skin_type":"waterOil", "acne":"smoothness", "wrinkles":"aging"}
MODEL_LOCK = threading.RLock()
_CACHE: dict[tuple[str,str], tuple[object,object,tuple]] = {}


def _file_signature(folder: Path, spec: dict) -> tuple:
    return tuple((f["name"], (folder/f["name"]).stat().st_size, (folder/f["name"]).stat().st_mtime_ns) for f in spec["files"])


def verify_artifact(path: Path, record: dict) -> bool:
    if not path.is_file() or path.stat().st_size != record["bytes"]:
        return False
    sha256 = hashlib.sha256()
    blob = hashlib.sha1(f"blob {record['bytes']}\0".encode())
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024*1024), b""):
            sha256.update(chunk); blob.update(chunk)
    return sha256.hexdigest() == record["sha256"] if record.get("sha256") else blob.hexdigest() == record["git_blob_sha1"]


def availability(root: Path | None, *, verify: bool = True) -> list[dict]:
    """A safe operator/client status, deliberately without local paths or secrets."""
    runtime = importlib.util.find_spec("torch") is not None and importlib.util.find_spec("transformers") is not None
    states=[]
    for key,spec in MODEL_SPECS.items():
        state = "disabled" if root is None else "ready"
        if root is not None:
            folder=root/key/spec["revision"]
            if not all((folder/f["name"]).is_file() for f in spec["files"]): state="not_downloaded"
            elif verify and not all(verify_artifact(folder/f["name"],f) for f in spec["files"]): state="checksum_mismatch"
            elif not runtime: state="runtime_not_installed"
        states.append({"id":key,"state":state,"repository":spec["repo"],"revision":spec["revision"],
                       "license":spec["license"],"modelSHA256":next(f["sha256"] for f in spec["files"] if f["name"]=="model.safetensors"),
                       "confidenceMeaning":"softmax_not_accuracy","spatialOutput":False})
    return states


def _load(root: Path,key: str):
    spec=MODEL_SPECS[key];folder=root/key/spec["revision"]
    signature=_file_signature(folder,spec)
    cache_key=(str(root.resolve()),key)
    cached=_CACHE.get(cache_key)
    if cached and cached[2]==signature: return cached[0],cached[1]
    if not all(verify_artifact(folder/f["name"],f) for f in spec["files"]):
        raise ValueError("checksum_mismatch")
    # These concrete built-in architectures cannot invoke repository-provided code.
    import torch
    from transformers import ViTForImageClassification, ViTImageProcessor
    torch.set_num_threads(min(4, max(1, torch.get_num_threads())))
    config=json.loads((folder/"config.json").read_text(encoding="utf-8"))
    if config.get("architectures") != ["ViTForImageClassification"] or config.get("model_type") != "vit":
        raise ValueError("unsupported_architecture")
    processor=ViTImageProcessor.from_pretrained(str(folder),local_files_only=True)
    model=ViTForImageClassification.from_pretrained(str(folder),local_files_only=True,
                                                   use_safetensors=True,attn_implementation="eager")
    model.to("cpu");model.eval()
    if set(int(k) for k in model.config.id2label) != set(range(model.config.num_labels)):
        raise ValueError("invalid_class_labels")
    _CACHE[cache_key]=(processor,model,signature)
    return processor,model


def classify(image: Image.Image, root: Path | None, progress: Callable[[int],None] | None = None) -> list[dict]:
    """Classify an already quality-checked face crop, always CPU/local-only."""
    status=availability(root)
    output=[]
    rgb=image.convert("RGB")
    input_digest=hashlib.sha256(rgb.tobytes()).hexdigest()
    for index,entry in enumerate(status):
        if progress: progress(index)
        observation=dict(entry)
        if entry["state"]=="ready" and root is not None:
            started=time.perf_counter()
            try:
                with MODEL_LOCK:
                    processor,model=_load(root,entry["id"])
                    import torch
                    inputs=processor(images=rgb,return_tensors="pt")
                    with torch.inference_mode():
                        logits=model(**inputs).logits[0].float()
                        probabilities=torch.softmax(logits,dim=-1).cpu().tolist()
                    if not probabilities or any(not math.isfinite(p) or not 0<=p<=1 for p in probabilities):
                        raise ValueError("invalid_probabilities")
                    best=max(range(len(probabilities)),key=probabilities.__getitem__)
                    observation.update({"label":str(model.config.id2label[best]),"confidence":probabilities[best],"uncertain":probabilities[best]<0.60,
                        "probabilities":[{"label":str(model.config.id2label[i]),"probability":p} for i,p in enumerate(probabilities)],
                        "inputSHA256":input_digest,"inputWidth":rgb.width,"inputHeight":rgb.height,
                        "runtime":"pytorch_cpu_safetensors","elapsedMs":round((time.perf_counter()-started)*1000,2)})
            except (ImportError,ModuleNotFoundError):
                observation["state"]="runtime_not_installed"
            except Exception:
                # Never expose exception strings, local paths or user image contents.
                observation["state"]="inference_failed"
        output.append(observation)
        if progress: progress(index+1)
    return output


def augment_report(report: dict, observations: list[dict], *, crop: tuple[float,float,float,float] | None = None) -> dict:
    """Append trained observations without inventing lesion locations or scores."""
    counts=0
    for observation in observations:
        key=observation["id"]
        dimension=next(m for m in report["skin"] if m["dimension"]==DIMENSIONS[key])
        base_id="trained-"+key
        dimension["items"]=[i for i in dimension["items"] if not i["id"].startswith(base_id)]
        provenance=f"{observation['repository']}@{observation['revision']}; weights SHA256={observation['modelSHA256']}; {observation['license']}"
        if observation["state"]=="ready" and "label" in observation:
            counts+=1
            note=("实际本地CPU推理；confidence是本模型softmax置信度，不是准确率、严重度百分数或仪器测量。"
                  "整张面部裁剪分类，没有逐像素定位，因此不生成此分类器的病变mask或计数。"+provenance)
            if key=="acne":
                note+="类别严格使用checkpoint config.id2label（level -1/0/1/2/3），不补README中未进入权重配置的level4，不区分丘疹/结节/粉刺。"
            if key=="skin_type":note+="dry/normal/oily是图像类别，不换算含水量或皮脂量。"
            if key=="wrinkles":note+="wrinkle/non-wrinkle不是肤龄、松弛程度或皱纹根数。"
            if crop:note+="输入为检测后面部裁剪，归一化边界="+','.join(f'{v:.4f}' for v in crop)+"。"
            if observation.get("uncertain"):
                note+="最高类概率低于0.60的界面提示阈值，按不确定候选展示；该阈值不是经验证的校准阈值。"
            value_prefix="不确定候选 · " if observation.get("uncertain") else ""
            dimension["items"].append({"id":base_id,"title":TITLES[key],
                "valueText":value_prefix+f"{observation['label']} · 模型置信度 {observation['confidence']*100:.1f}%",
                "note":note,"overlayID":None})
            dimension["items"].append({"id":base_id+"-distribution","title":"模型类别分布",
                "valueText":" · ".join(f"{p['label']} {p['probability']*100:.1f}%" for p in observation["probabilities"]),
                "note":"本模型输出各类softmax概率，保留原始类别顺序；未做人群校准。输入RGB摘要="+observation["inputSHA256"],"overlayID":None})
            report["modelVersion"] += "; "+key+"@"+observation["revision"][:12]+"-"+observation["modelSHA256"][:12]
        else:
            dimension["items"].append({"id":base_id,"title":TITLES[key],"valueText":"未运行 · "+observation["state"],
                "note":"本次没有该模型的可靠推理结果，不填造分类、位置、计数或分数。"+provenance,"overlayID":None})
    report["quality"].append({"id":"trained_skin_models","title":"训练分类模型",
        "passed":counts==len(MODEL_SPECS),"detail":f"实际完成{counts}/{len(MODEL_SPECS)}个本地训练分类器；未完成项单独列状态，confidence不代表准确率。"})
    if counts:
        report["summary"] += f"另有{counts}个已固定版本的训练分类器完成本地面部图像分类，详见分项原始类别与置信度；未把分类输出转为生理分或像素mask。"
    return report
