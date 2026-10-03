#!/usr/bin/env python3
import pathlib, plistlib, subprocess, sys
app = pathlib.Path(sys.argv[1])
expected = {'UploadVideo', 'ScreenRec', 'ScreenRecSetupUI', 'Carplayintent', 'CarplayintentUI', 'SelfAirPlayTunnel', 'TDSCarPlayControlsWidget'}
actual = {p.stem for p in (app/'PlugIns').glob('*.appex')}
assert expected == actual, f'Embedded extensions mismatch: missing={expected-actual}, extra={actual-expected}'
info = plistlib.loads((app/'Info.plist').read_bytes())
assert info['CFBundleIdentifier'] == 'com.ali.carcasthub'
assert info.get('CFBundleSupportedPlatforms') == ['iPhoneOS'], 'Not a device build'
for bundle in [app, *sorted((app/'PlugIns').glob('*.appex'))]:
    p = plistlib.loads((bundle/'Info.plist').read_bytes())
    binary = bundle/p['CFBundleExecutable']
    assert binary.is_file(), f'Missing executable: {bundle.name}'
    arch = subprocess.check_output(['lipo','-archs',str(binary)],text=True)
    assert 'arm64' in arch, f'No arm64 executable: {bundle.name}'
print('Device app and all seven embedded extensions verified.')
