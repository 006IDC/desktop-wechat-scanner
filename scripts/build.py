#!/usr/bin/env python3
from pathlib import Path
import subprocess
import zipfile
import os
import tempfile

root = Path(__file__).resolve().parents[1]
def one(pattern):
    paths = list(root.glob(pattern))
    if len(paths) != 1:
        raise SystemExit(f'Expected one {pattern}, found {len(paths)}; run bootstrap.py first')
    return paths[0]

javac = one('.tools/jdk/*/Contents/Home/bin/javac')
java = javac.with_name('java')
android = one('.tools/sdk-platform/*/android.jar')
d8 = one('.tools/sdk-build/*/lib/d8.jar')
(root/'build').mkdir(exist_ok=True)
(root/'.local').mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix='classes-',dir=root/'build') as directory:
    classes=Path(directory)
    subprocess.run([str(javac), '--release', '17', '-cp', str(android), '-d', str(classes), *map(str, (root/'src').glob('*.java'))], check=True)
    with zipfile.ZipFile(root/'build/classes.jar', 'w') as z:
        for path in classes.rglob('*.class'):
            z.write(path, path.relative_to(classes))
subprocess.run([str(java), '-cp', str(d8), 'com.android.tools.r8.D8', '--lib', str(android), '--min-api', '34', '--output', str(root/'build/camera-probe.jar'), str(root/'build/classes.jar')], check=True)
print('Built build/camera-probe.jar')
tools=d8.parent.parent
subprocess.run([str(tools/'aapt2'),'link','--manifest',str(root/'src/AndroidManifest.xml'),'-I',str(android),'-o',str(root/'build/base.apk')],check=True)
with zipfile.ZipFile(root/'build/base.apk') as base, zipfile.ZipFile(root/'build/camera-probe.jar') as dex, zipfile.ZipFile(root/'build/test-unsigned.apk','w') as output:
    for z in (base,dex):
        for info in z.infolist():
            output.writestr(info,z.read(info))
key=root/'.local/test-only.p12'
env={**os.environ,'QR_PROBE_TEST_PASS':'android'}
if not key.exists():
    subprocess.run([str(java.with_name('keytool')),'-genkeypair','-keystore',str(key),'-storetype','PKCS12','-storepass:env','QR_PROBE_TEST_PASS','-keypass:env','QR_PROBE_TEST_PASS','-alias','local-test','-keyalg','RSA','-keysize','2048','-validity','30','-dname','CN=Local QR Prototype Test Only'],env=env,check=True)
    key.chmod(0o600)
subprocess.run([str(java),'-jar',str(tools/'lib/apksigner.jar'),'sign','--ks',str(key),'--ks-pass','env:QR_PROBE_TEST_PASS','--out',str(root/'build/qr-self-test.apk'),str(root/'build/test-unsigned.apk')],env=env,check=True)
subprocess.run([str(java),'-jar',str(tools/'lib/apksigner.jar'),'verify',str(root/'build/qr-self-test.apk')],check=True)
print('Built and signature-verified build/qr-self-test.apk (test key only)')
cache=root/'.tools/swift-cache'
cache.mkdir(parents=True,exist_ok=True)
for source,output in [('qr.swift','qr-helper'),('desktop_source.swift','desktop-source')]:
    subprocess.run(['swiftc','-module-cache-path',str(cache),str(root/'scripts'/source),'-o',str(root/'build'/output)],check=True)
print('Built native Mac QR and own-window capture helpers')
