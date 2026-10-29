#!/usr/bin/env python3
"""Build a signed Mac app ZIP. build/*.app is an unsigned intermediate only."""
import argparse
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import tempfile
import zipfile

ROOT=Path(__file__).resolve().parents[1]
APP=ROOT/'build/MiraDroid.app'
STABLE_ZIP=ROOT/'build/MiraDroid-本机签名.zip'
AD_HOC_ZIP=ROOT/'build/MiraDroid-ad-hoc.zip'
parser=argparse.ArgumentParser(description=__doc__)
signing=parser.add_mutually_exclusive_group()
signing.add_argument('--local-signing',action='store_true',
                     help='use the persistent project-local identity (the default; kept for existing commands)')
signing.add_argument('--ad-hoc',action='store_true',
                     help='make a separate ad-hoc signed test ZIP; cannot be installed by this script')
parser.add_argument('--install',type=Path,metavar='PATH',
                    help='install the verified stable-signed app at this explicit .app path')
args=parser.parse_args()
if args.ad_hoc and args.install:
    parser.error('--ad-hoc is test-only and cannot be combined with --install')
ZIP=AD_HOC_ZIP if args.ad_hoc else STABLE_ZIP
revision=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
if subprocess.check_output(['git','status','--porcelain'],cwd=ROOT,text=True).strip():
    raise RuntimeError('Commit all source changes before building an app')

def copy_without_metadata(source: str, destination: str) -> str:
    """Copy bytes and POSIX mode; never transfer FinderInfo or ResourceFork."""
    shutil.copyfile(source,destination)
    os.chmod(destination,stat.S_IMODE(os.stat(source).st_mode))
    return destination

def verify(path: Path) -> None:
    subprocess.run(['codesign','--verify','--deep','--strict',str(path)],check=True)

def package_zip(staged: Path) -> None:
    temporary=ZIP.with_name(ZIP.name+'.tmp')
    try:
        with zipfile.ZipFile(temporary,'w',compression=zipfile.ZIP_DEFLATED,
                             compresslevel=9,allowZip64=True) as archive:
            for path in sorted(staged.rglob('*')):
                if path.is_symlink():
                    raise RuntimeError(f'Unexpected symlink in app bundle: {path}')
                if not path.is_file():
                    continue
                relative=Path(APP.name)/path.relative_to(staged)
                entry=zipfile.ZipInfo.from_file(path,arcname=str(relative))
                entry.compress_type=zipfile.ZIP_DEFLATED
                entry.create_system=3
                with path.open('rb') as source, archive.open(entry,'w') as output:
                    shutil.copyfileobj(source,output)
        with zipfile.ZipFile(temporary,'r') as archive:
            corrupt=archive.testzip()
            if corrupt:
                raise RuntimeError(f'ZIP CRC failed: {corrupt}')
            for name in ('Contents/MacOS/DesktopWeChatScanner',):
                entry=archive.getinfo(f'{APP.name}/{name}')
                if not (entry.external_attr >> 16) & 0o111:
                    raise RuntimeError(f'ZIP lost executable mode: {name}')
        temporary.replace(ZIP)
    finally:
        temporary.unlink(missing_ok=True)

def install(staged: Path, target: Path, bundle_id: str) -> None:
    target=target.expanduser()
    if not target.is_absolute() or target.suffix != '.app':
        raise ValueError('--install requires an absolute .app path')
    if not target.parent.is_dir() or target.is_symlink():
        raise ValueError('Install parent must exist and target cannot be a symlink')
    if target.exists():
        if not target.is_dir():
            raise ValueError('Install target is not an app directory')
        try:
            with (target/'Contents/Info.plist').open('rb') as stream:
                installed=plistlib.load(stream)
        except (OSError,ValueError) as error:
            raise ValueError('Cannot identify existing app; refusing to overwrite') from error
        if installed.get('CFBundleIdentifier') != bundle_id:
            raise ValueError('Existing app has a different bundle identifier; refusing to overwrite')
    with tempfile.TemporaryDirectory(prefix='006idc-app-install-',dir=target.parent) as folder:
        work=Path(folder)
        candidate=work/APP.name
        backup=work/'previous.app'
        shutil.copytree(staged,candidate,copy_function=copy_without_metadata)
        verify(candidate)
        had_previous=target.exists()
        if had_previous:
            target.rename(backup)
        try:
            candidate.rename(target)
            verify(target)
        except Exception:
            if target.exists():
                shutil.rmtree(target)
            if had_previous and backup.exists():
                backup.rename(target)
            raise

subprocess.run(['python3',str(ROOT/'scripts/bootstrap_adb.py')],check=True)
subprocess.run(['python3',str(ROOT/'scripts/build.py')],check=True)
subprocess.run(['python3',str(ROOT/'scripts/bootstrap_mirror.py')],check=True)
icon_tool=ROOT/'build/generate-icon'
subprocess.run(['swiftc','-swift-version','5','-O','-target','arm64-apple-macos14.4',
                '-module-cache-path',str(ROOT/'.local/swift-cache'),
                str(ROOT/'scripts/icon.swift'),'-o',str(icon_tool)],check=True)
subprocess.run([str(icon_tool)],cwd=ROOT,check=True)
contents=APP/'Contents'
resources=contents/'Resources'
binary=contents/'MacOS'
resources.mkdir(parents=True,exist_ok=True)
binary.mkdir(parents=True,exist_ok=True)
info={
    'CFBundleIdentifier':'com.idc006.DesktopWeChatScanner',
    'CFBundleName':'MiraDroid','CFBundleDisplayName':'MiraDroid',
    'CFBundleExecutable':'DesktopWeChatScanner','CFBundlePackageType':'APPL',
    'CFBundleShortVersionString':'0.4.0','CFBundleVersion':'52',
    'DesktopScannerRelease':'0.4.0-preview.5',
    'CFBundleIconFile':'AppIcon.icns',
    'LSMinimumSystemVersion':'14.4','NSHighResolutionCapable':True,
    'NSLocalNetworkUsageDescription':'连接同一局域网内已由你配对授权的 Android 手机，以显示镜像并发送点击。',
    'NSBonjourServices':['_adb-tls-connect._tcp'],
    'NSScreenCaptureUsageDescription':'将透明取景框选中的电脑画面提供给所选手机应用的相机。',
    'NSPrincipalClass':'NSApplication',
}
with (contents/'Info.plist').open('wb') as stream:plistlib.dump(info,stream)
for source,dest in [('build/camera-probe.jar','camera-probe.jar'),('.tools/scrcpy/scrcpy-server-v5.0.1','scrcpy-server'),('third_party/scrcpy/LICENSE','SCRCPY-LICENSE.txt')]:
    shutil.copy2(ROOT/source,resources/dest)
shutil.copy2(ROOT/'build/AppIcon.icns',resources/'AppIcon.icns')
for name in ('LICENSE','NOTICE','THIRD_PARTY.md'):
    shutil.copy2(ROOT/name,resources/name)
# The bundle is built from pinned open source, with its sources and licenses.
if (resources/'adb').exists():
    shutil.rmtree(resources/'adb')
shutil.copytree(ROOT/'.local/adb-bundle',resources/'adb',copy_function=copy_without_metadata)
(resources/'SOURCE-REVISION.txt').write_text(revision+'\n')
subprocess.run(['swiftc','-swift-version','5','-O','-target','arm64-apple-macos14.4',
                '-file-prefix-map',str(ROOT)+'=/source/desktop-wechat-scanner',
                '-debug-prefix-map',str(ROOT)+'=/source/desktop-wechat-scanner',
                '-module-cache-path',str(ROOT/'.local/swift-cache'),*map(str,sorted((ROOT/'mac').glob('*.swift'))),'-o',str(binary/'DesktopWeChatScanner')],check=True)
if subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip() != revision or subprocess.check_output(['git','status','--porcelain'],cwd=ROOT,text=True).strip():
    raise RuntimeError('Source changed during build; refuse to package')
# A Documents File Provider continuously adds FinderInfo to .app roots.
# Build there, then sign and verify a metadata-free staging copy outside it.
# Only the ZIP (or an explicit --install target) is a deliverable.
with tempfile.TemporaryDirectory(prefix='006idc-app-sign-') as temp:
    staged=Path(temp)/APP.name
    shutil.copytree(APP,staged,copy_function=copy_without_metadata)
    # copytree may preserve directory xattrs even when its file copier does not.
    for name in ('com.apple.FinderInfo','com.apple.ResourceFork'):
        subprocess.run(['xattr','-dr',name,str(staged)],
                       stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    if not args.ad_hoc:
        from local_signing import KEYCHAIN, fingerprint
        signing_identity=fingerprint()
        signing_args=['--keychain',str(KEYCHAIN),'--sign',signing_identity]
    else:
        signing_args=['--sign','-']
    subprocess.run(['codesign','--force',*signing_args,'--identifier',info['CFBundleIdentifier'],str(staged)],check=True)
    verify(staged)
    package_zip(staged)
    if args.install:
        install(staged,args.install,info['CFBundleIdentifier'])
        print(f'Installed and verified: {args.install}')
print(f'Verified ZIP: {ZIP}')
print(f'Intermediate only (may receive Finder metadata): {APP}')
