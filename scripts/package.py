"""Create a portable source bundle, excluding runtimes, private photos, tokens and models."""
from pathlib import Path
import hashlib
import json
import sys
import zipfile

root = Path(__file__).resolve().parents[1]
destination = Path(sys.argv[1]) if len(sys.argv)>1 else root.parent/'RuyuanAesthetics-iOS.zip'
excluded = {'.venv','.qa-tools','__pycache__','.pytest_cache','.build','DerivedData','xcuserdata',
            'private-data','data','models','.git','.mypy_cache','.ruff_cache'}
allowed_roots = {'iOS','backend','docs','scripts','.github'}
root_files = {'README.md','.gitignore','.gitattributes','打开如愿美学.command'}
files = []
for path in root.rglob('*'):
    if not path.is_file():continue
    rel=path.relative_to(root)
    if rel.parts[0] not in allowed_roots and rel.as_posix() not in root_files:continue
    if any(part in excluded for part in rel.parts):continue
    if path.name == '.env' or path.suffix.lower() in {'.pyc','.whl','.db','.sqlite','.sqlite3','.task','.mp4','.jpg','.jpeg','.ipa'}:continue
    files.append((rel,path))
files.sort(key=lambda x:x[0].as_posix())
manifest = '\n'.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {rel.as_posix()}' for rel,p in files)+'\n'
destination.parent.mkdir(parents=True,exist_ok=True)
with zipfile.ZipFile(destination,'w',zipfile.ZIP_DEFLATED,compresslevel=9) as archive:
    for rel,path in files:
        info=zipfile.ZipInfo('RuyuanAesthetics/'+rel.as_posix())
        info.create_system=3
        mode=0o755 if path.suffix in {'.sh','.command'} else 0o644
        info.external_attr=(0o100000|mode)<<16
        info.compress_type=zipfile.ZIP_DEFLATED
        archive.writestr(info,path.read_bytes())
    archive.writestr('RuyuanAesthetics/MANIFEST.sha256',manifest)
with zipfile.ZipFile(destination) as archive:
    assert archive.testzip() is None
    assert not any(any(part in excluded for part in Path(n).parts) for n in archive.namelist())
receipt={'file':str(destination),'files':len(files)+1,'bytes':destination.stat().st_size,
         'sha256':hashlib.sha256(destination.read_bytes()).hexdigest()}
print(json.dumps(receipt,ensure_ascii=False,indent=2))
