"""Deterministic, dependency-free Xcode project generator. Run after adding Swift files."""
from pathlib import Path
import hashlib
import json
import plistlib

ROOT = Path(__file__).resolve().parents[1]
IOS = ROOT / 'iOS'
PROJECT = IOS / 'Ruyuan.xcodeproj'
PROJECT.mkdir(exist_ok=True)

def uid(value):
    return hashlib.sha1(value.encode()).hexdigest()[:24].upper()

def q(value):
    return json.dumps(str(value), ensure_ascii=False)

objects = []
def obj(key, value):
    objects.append(f'\t\t{uid(key)} = {{ {value} }};')

def ref(key): return uid(key)
def ids(keys): return '(' + ', '.join(ref(k) for k in keys) + ', )' if keys else '()'
def config(key, settings):
    text = ' '.join(f'{k} = {q(v)};' for k, v in settings.items())
    obj(key, f'isa = XCBuildConfiguration; buildSettings = {{ {text} }}; name = {q(key.split(":")[-1])};')

app = sorted((IOS / 'Ruyuan').rglob('*.swift'))
tests = sorted((IOS / 'RuyuanTests').rglob('*.swift'))
ui_tests = sorted((IOS / 'RuyuanUITests').rglob('*.swift')) if (IOS / 'RuyuanUITests').exists() else []
resources = [('Ruyuan/Resources/Assets.xcassets','folder.assetcatalog'),
             ('Ruyuan/Resources/PrivacyInfo.xcprivacy','text.xml'),
             ('Ruyuan/Resources/Models/selfie_multiclass_256x256.tflite','file'),
             ('Ruyuan/Resources/Models/SelfieMulticlass-APACHE-2.0.txt','text'),
             ('Ruyuan/Resources/Models/face_landmarker.bin','file'),
             ('Ruyuan/Resources/Models/FaceLandmarker-APACHE-2.0.txt','text'),
             ('Ruyuan/Resources/Models/PoreNet.mlmodel','file.mlmodel'),
             ('Ruyuan/Resources/Models/PoreNet-resource-manifest.json','text.json'),
             ('Ruyuan/Resources/Models/PoreNet-fixture-reference.json','text.json'),
             ('Ruyuan/Resources/Models/LICENSE-PoreNet.txt','text'),
             ('Ruyuan/Resources/Models/AcneSegmentation.mlmodel','file.mlmodel'),
             ('Ruyuan/Resources/Models/AcneSegmentation-resource-manifest.json','text.json'),
             ('Ruyuan/Resources/Models/AcneSegmentation-fixture-reference.json','text.json'),
             ('Ruyuan/Resources/Models/LICENSE-AcneSegmentation.txt','text')]
coreml_root = IOS / 'Ruyuan/Resources/CoreML'
for package in sorted(coreml_root.glob('*.mlpackage')):
    resources.append((package.relative_to(IOS).as_posix(), 'folder.mlpackage'))
if (coreml_root/'coreml-model-manifest.json').is_file():
    resources += [('Ruyuan/Resources/CoreML/coreml-model-manifest.json', 'text.json'),
                  ('Ruyuan/Resources/CoreML/source-notices', 'folder')]

# Exact official source revision; binary targets include their own SHA-256 pins.
obj('package:mediapipe', 'isa = XCRemoteSwiftPackageReference; repositoryURL = "https://github.com/google-ai-edge/mediapipe"; requirement = { kind = revision; revision = "3c49477cd79f753fbe943d814b917e3c8c0bf404"; };')
obj('packageproduct:vision', f'isa = XCSwiftPackageProductDependency; package = {ref("package:mediapipe")}; productName = MediaPipeTasksVision;')
obj('frameworkbuild:vision', f'isa = PBXBuildFile; productRef = {ref("packageproduct:vision")};')
group_files = {'app': [], 'tests': [], 'ui': []}
for group, files in [('app',app),('tests',tests),('ui',ui_tests)]:
    for file in files:
        path = file.relative_to(IOS).as_posix()
        key = 'file:' + path
        obj(key, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; name = {q(file.name)}; path = {q(path)}; sourceTree = "<group>";')
        obj('build:'+path, f'isa = PBXBuildFile; fileRef = {ref(key)};')
        group_files[group].append(key)

for path, kind in resources:
    obj('file:'+path, f'isa = PBXFileReference; lastKnownFileType = {kind}; path = {q(path)}; sourceTree = "<group>";')
    obj('build:'+path, f'isa = PBXBuildFile; fileRef = {ref("file:"+path)};')
    group_files['app'].append('file:'+path)

for path in ['Ruyuan/Info.plist']:
    obj('file:'+path, f'isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = {q(path)}; sourceTree = "<group>";')
    group_files['app'].append('file:'+path)

target_names = [('app','Ruyuan','com.apple.product-type.application','Ruyuan.app','wrapper.application')]
if tests: target_names.append(('tests','RuyuanTests','com.apple.product-type.bundle.unit-test','RuyuanTests.xctest','wrapper.cfbundle'))
if ui_tests: target_names.append(('ui','RuyuanUITests','com.apple.product-type.bundle.ui-testing','RuyuanUITests.xctest','wrapper.cfbundle'))
for group,name,ptype,product,filetype in target_names:
    obj('product:'+group, f'isa = PBXFileReference; explicitFileType = {filetype}; includeInIndex = 0; path = {q(product)}; sourceTree = BUILT_PRODUCTS_DIR;')
    obj('group:'+group, f'isa = PBXGroup; children = {ids(group_files[group])}; name = {q(name)}; sourceTree = "<group>";')
    paths = [p.relative_to(IOS).as_posix() for p in (app if group=='app' else tests if group=='tests' else ui_tests)]
    obj('sources:'+group, f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {ids(["build:"+p for p in paths])}; runOnlyForDeploymentPostprocessing = 0;')
    obj('frameworks:'+group, f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = {ids(["frameworkbuild:vision"] if group=="app" else [])}; runOnlyForDeploymentPostprocessing = 0;')
    obj('resources:'+group, f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = {ids(["build:"+p for p,k in resources] if group=="app" else [])}; runOnlyForDeploymentPostprocessing = 0;')
    dependencies=[]
    if group != 'app':
        obj('proxy:'+group, f'isa = PBXContainerItemProxy; containerPortal = {ref("project")}; proxyType = 1; remoteGlobalIDString = {ref("target:app")}; remoteInfo = Ruyuan;')
        obj('dependency:'+group, f'isa = PBXTargetDependency; target = {ref("target:app")}; targetProxy = {ref("proxy:"+group)};')
        dependencies=['dependency:'+group]
    obj('target:'+group, f'isa = PBXNativeTarget; buildConfigurationList = {ref("configlist:"+group)}; buildPhases = {ids(["sources:"+group,"frameworks:"+group,"resources:"+group])}; buildRules = (); dependencies = {ids(dependencies)}; packageProductDependencies = {ids(["packageproduct:vision"] if group=="app" else [])}; name = {name}; productName = {name}; productReference = {ref("product:"+group)}; productType = {q(ptype)};')
    for mode in ['Debug','Release']:
        settings = {'ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon','CODE_SIGN_STYLE':'Automatic',
                    'CURRENT_PROJECT_VERSION':'10','MARKETING_VERSION':'0.3.0','IPHONEOS_DEPLOYMENT_TARGET':'17.0',
                    'PRODUCT_BUNDLE_IDENTIFIER':'com.ruyuan.aesthetics' + ('.tests' if group=='tests' else '.uitests' if group=='ui' else ''),
                    'PRODUCT_NAME':'$(TARGET_NAME)','SDKROOT':'iphoneos','SUPPORTED_PLATFORMS':'iphoneos iphonesimulator',
                    'SWIFT_VERSION':'5.0','SWIFT_STRICT_CONCURRENCY':'targeted','TARGETED_DEVICE_FAMILY':'1',
                    'SUPPORTS_MACCATALYST':'NO','SWIFT_EMIT_LOC_STRINGS':'YES',
                    'LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks'}
        if group=='app':
            settings.update({'GENERATE_INFOPLIST_FILE':'NO','INFOPLIST_FILE':'Ruyuan/Info.plist','ENABLE_PREVIEWS':'YES'})
        else:
            settings.pop('ASSETCATALOG_COMPILER_APPICON_NAME')
            settings.update({'GENERATE_INFOPLIST_FILE':'YES'})
            if group=='tests':settings.update({'BUNDLE_LOADER':'$(TEST_HOST)','TEST_HOST':'$(BUILT_PRODUCTS_DIR)/Ruyuan.app/Ruyuan'})
            else:settings['TEST_TARGET_NAME']='Ruyuan'
        model_flag = ' RUYUAN_COREML_BUNDLED' if len(list(coreml_root.glob('*.mlpackage'))) == 3 else ''
        if mode=='Debug':settings.update({'SWIFT_OPTIMIZATION_LEVEL':'-Onone','SWIFT_ACTIVE_COMPILATION_CONDITIONS':'DEBUG $(inherited)'+model_flag})
        else:settings.update({'SWIFT_OPTIMIZATION_LEVEL':'-O','VALIDATE_PRODUCT':'YES'})
        config('config:'+group+':'+mode,settings)
    obj('configlist:'+group, f'isa = XCConfigurationList; buildConfigurations = {ids(["config:"+group+":Debug","config:"+group+":Release"])}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')

obj('products', f'isa = PBXGroup; children = {ids(["product:"+x[0] for x in target_names])}; name = Products; sourceTree = "<group>";')
obj('main', f'isa = PBXGroup; children = {ids(["group:"+x[0] for x in target_names]+["products"])}; sourceTree = "<group>";')
for mode in ['Debug','Release']:
    config('config:project:'+mode, {'ALWAYS_SEARCH_USER_PATHS':'NO','CLANG_ENABLE_MODULES':'YES','CLANG_ENABLE_OBJC_ARC':'YES',
            'ENABLE_USER_SCRIPT_SANDBOXING':'YES','GCC_C_LANGUAGE_STANDARD':'gnu17','CLANG_CXX_LANGUAGE_STANDARD':'gnu++20',
            'DEBUG_INFORMATION_FORMAT':'dwarf' if mode=='Debug' else 'dwarf-with-dsym','ENABLE_TESTABILITY':'YES' if mode=='Debug' else 'NO'})
obj('configlist:project', f'isa = XCConfigurationList; buildConfigurations = {ids(["config:project:Debug","config:project:Release"])}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
obj('project', f'isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = 1; LastSwiftUpdateCheck = 1600; LastUpgradeCheck = 1600; }}; buildConfigurationList = {ref("configlist:project")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = "zh-Hans"; hasScannedForEncodings = 0; knownRegions = ("zh-Hans", en, Base); mainGroup = {ref("main")}; productRefGroup = {ref("products")}; packageReferences = {ids(["package:mediapipe"])}; projectDirPath = ""; projectRoot = ""; targets = {ids(["target:"+x[0] for x in target_names])};')
content = '// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 56;\n\tobjects = {\n' + '\n'.join(objects) + f'\n\t}};\n\trootObject = {ref("project")};\n}}\n'
(PROJECT/'project.pbxproj').write_text(content,encoding='utf-8')

def buildable(group,name,product):
    return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ref("target:"+group)}" BuildableName="{product}" BlueprintName="{name}" ReferencedContainer="container:Ruyuan.xcodeproj"/>'
app_ref=buildable('app','Ruyuan','Ruyuan.app')
testables=''.join(f'<TestableReference skipped="NO">{buildable(g,n,p)}</TestableReference>' for g,n,_,p,_ in target_names if g!='app')
scheme=f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
  <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{app_ref}</BuildActionEntry>
 </BuildActionEntries></BuildAction>
 <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables>{testables}</Testables></TestAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app_ref}</BuildableProductRunnable></LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app_ref}</BuildableProductRunnable></ProfileAction>
 <AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>'''
schemes=PROJECT/'xcshareddata'/'xcschemes';schemes.mkdir(parents=True,exist_ok=True)
(schemes/'Ruyuan.xcscheme').write_text(scheme,encoding='utf-8')
workspace=PROJECT/'project.xcworkspace';workspace.mkdir(exist_ok=True)
(workspace/'contents.xcworkspacedata').write_text('<?xml version="1.0" encoding="UTF-8"?><Workspace version="1.0"><FileRef location="self:"/></Workspace>',encoding='utf-8')
print(f'Generated {PROJECT.name}: {len(app)} app sources, {len(tests)} unit files, {len(ui_tests)} UI files')
