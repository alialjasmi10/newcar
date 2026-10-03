#!/usr/bin/env python3
"""Portable structural checks; not a substitute for xcodebuild/type checking."""
import json, pathlib, plistlib, re, sys, xml.etree.ElementTree as ET
root = pathlib.Path(__file__).resolve().parent.parent
source = (root/'TDS Video.xcodeproj/project.pbxproj').read_text()
tokens = re.findall(r'/\*[\s\S]*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"|[{}()=;,]|[^\s{}()=;,]+',source)
tokens = [t for t in tokens if not t.startswith(('/*','//'))]
i = 0
def take(expected=None):
    global i
    token=tokens[i]; i+=1
    if expected is not None: assert token==expected, (token,expected)
    return token
def value():
    if tokens[i]=='{':
        take('{'); result={}
        while tokens[i]!='}':
            key=take().strip('"'); take('='); result[key]=value(); take(';')
        take('}'); return result
    if tokens[i]=='(':
        take('('); result=[]
        while tokens[i]!=')':
            result.append(value())
            if tokens[i]==',':take(',')
        take(')'); return result
    return take().strip('"')
project=value(); assert i==len(tokens)
objects=project['objects']
targets={v['name']:v for v in objects.values() if v.get('isa')=='PBXNativeTarget'}
expected={'TDS Video','UploadVideo','ScreenRec','ScreenRecSetupUI','Carplayintent','CarplayintentUI','SelfAirPlayTunnel','TDSCarPlayControlsWidget'}
assert set(targets)==expected
for t in targets.values():
    for ref in t['buildPhases']+t.get('dependencies',[]): assert ref in objects
    config=objects[t['buildConfigurationList']]
    for ref in config['buildConfigurations']:
        settings=objects[ref]['buildSettings']
        for key in ('CODE_SIGN_ENTITLEMENTS','INFOPLIST_FILE','SWIFT_OBJC_BRIDGING_HEADER'):
            if settings.get(key):assert (root/settings[key]).is_file(),settings[key]
        assert settings.get('PRODUCT_BUNDLE_IDENTIFIER','').startswith('$(APP_BUNDLE_IDENTIFIER)')
for p in root.rglob('*'):
    if p.suffix in ('.plist','.entitlements'):plistlib.loads(p.read_bytes())
    if p.suffix in ('.xcscheme','.storyboard','.xib'):ET.parse(p)
    if p.name=='Contents.json':json.loads(p.read_text())
scheme=ET.parse(root/'TDS Video.xcodeproj/xcshareddata/xcschemes/TDS Video.xcscheme')
for ref in scheme.findall('.//BuildableReference'):assert ref.attrib['BlueprintIdentifier'] in objects
app=targets['TDS Video']
embedded=[]
for phaseID in app['buildPhases']:
    phase=objects[phaseID]
    if phase['isa']=='PBXCopyFilesBuildPhase':
        embedded += [objects[objects[f]['fileRef']]['path'] for f in phase['files']]
assert len([p for p in embedded if p.endswith('.appex')])==7,embedded
for p in (root/'TDS Video/Hub').glob('*.swift'):
    text=p.read_text(); assert 'print(' not in text, f'Diagnostic log in new code: {p.name}'
assert 'rootView: HubRootView()' in (root/'TDS Video/ViewController.swift').read_text()
assert 'com.ali.carcasthub' in (root/'Config.xcconfig').read_text()
print('PASS: OpenStep project, eight targets, seven embedded extensions, schemes, property lists and resources.')
print('NOT RUN: Swift compiler, Xcode build, simulator, device playback, signing and CarPlay.')
