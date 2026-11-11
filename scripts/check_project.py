"""Portable structural checks. This is not an iOS compiler or simulator test."""
from pathlib import Path
import json
import plistlib
import re
import sys
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
ios = root / 'iOS'
pbx = (ios / 'Ruyuan.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
errors = []
swift = sorted(ios.rglob('*.swift'))
for path in swift:
    relative = path.relative_to(ios).as_posix()
    if f'path = "{relative}";' not in pbx:
        errors.append(f'Missing source reference: {relative}')
for path in re.findall(r'path = "(Ruyuan[^"\n]+)";', pbx):
    if not path.startswith(('Ruyuan/', 'RuyuanTests/', 'RuyuanUITests/')): continue
    if not (ios / path).exists(): errors.append(f'Missing file: {path}')
for path in [ios/'Ruyuan/Info.plist',ios/'Ruyuan/Resources/PrivacyInfo.xcprivacy']:
    plistlib.loads(path.read_bytes())
ET.parse(ios/'Ruyuan.xcodeproj/xcshareddata/xcschemes/Ruyuan.xcscheme')
for path in (ios/'Ruyuan/Resources/Assets.xcassets').rglob('Contents.json'):
    data = json.loads(path.read_text(encoding='utf-8'))
    for image in data.get('images',[]):
        if 'filename' in image and not (path.parent/image['filename']).exists():errors.append('Missing asset image')
print(f'Source references: {len(swift)} Swift files')
try:
    from tree_sitter import Language, Parser
    import tree_sitter_swift
except ImportError:
    print('Swift syntax scan: NOT RUN (install scripts/qa-requirements.txt for parser).')
else:
    parser = Parser(Language(tree_sitter_swift.language()))
    def scan(node, path):
        if node.type=='ERROR' or node.is_missing:
            errors.append(f'Swift grammar: {path.relative_to(root)}:{node.start_point.row+1}')
        for child in node.children: scan(child,path)
    for path in swift:scan(parser.parse(path.read_bytes()).root_node,path)
    print('Swift grammar scan completed (not SDK typechecking).')
print('Plist / XML / asset / source references:', 'PASS' if not errors else 'FAIL')
for error in errors: print(error)
sys.exit(1 if errors else 0)
