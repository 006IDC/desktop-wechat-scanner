#!/usr/bin/env python3
"""Package the verified app ZIP into public ZIP/DMG assets without installing it."""
from pathlib import Path, PurePosixPath
import hashlib
import json
import os
import plistlib
import shutil
import stat
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
RELEASE = '0.3.2-preview.1'
APP_NAME = '桌面微信扫码.app'
STEM = f'DesktopWeChatScanner-{RELEASE}-macOS-arm64'
OUT = ROOT / 'build/release'
SCRCPY_SHA256 = '764eb6f79811d5211fe9df341120882ba9994c7a61b897d7bf3fb662e53bc536'


def run(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def digest(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def verify(app):
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)


def extract_checked(source, folder):
    with zipfile.ZipFile(source) as archive:
        bad = archive.testzip()
        if bad:
            raise RuntimeError('Archive CRC failed')
        for item in archive.infolist():
            name = PurePosixPath(item.filename)
            mode = item.external_attr >> 16
            if name.is_absolute() or '..' in name.parts or name.parts[0] != APP_NAME or stat.S_ISLNK(mode):
                raise RuntimeError('Unexpected archive path/type')
            destination = folder.joinpath(*name.parts)
            if item.is_dir():
                destination.mkdir(parents=True, exist_ok=True)
            else:
                destination.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(item) as src, destination.open('wb') as dst:
                    shutil.copyfileobj(src, dst)
                destination.chmod(mode & 0o777)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    names = [STEM+'.zip', STEM+'.dmg', 'release-manifest.json', 'SHA256SUMS.txt']
    if any((OUT/name).exists() for name in names):
        raise RuntimeError('Release outputs already exist; do not overwrite a published artifact')
    revision = run('git', 'rev-parse', 'HEAD')
    if run('git', 'status', '--porcelain', '--untracked-files=no'):
        raise RuntimeError('Commit source changes before packaging')
    with tempfile.TemporaryDirectory(prefix='wechat-release-') as temporary:
        temp = Path(temporary)
        stage = temp/'stage'; stage.mkdir()
        extract_checked(ROOT/'build/桌面微信扫码.zip', stage)
        app = stage/APP_NAME
        verify(app)
        resources = app/'Contents/Resources'
        if (resources/'adb').exists():
            raise RuntimeError('Public app must not bundle adb')
        if (resources/'SOURCE-REVISION.txt').read_text().strip() != revision:
            raise RuntimeError('App source revision does not match current commit')
        info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
        if (info['CFBundleShortVersionString'], info['CFBundleVersion'], info['DesktopScannerRelease']) != ('0.3.2', '11', RELEASE):
            raise RuntimeError('Release/Info.plist mismatch')
        executable = app/'Contents/MacOS/DesktopWeChatScanner'
        if run('lipo', '-archs', str(executable)) != 'arm64' or not os.access(executable, os.X_OK):
            raise RuntimeError('Wrong architecture or missing executable mode')
        for name in ['LICENSE', 'NOTICE', 'THIRD_PARTY.md', 'SCRCPY-LICENSE.txt']:
            if not (resources/name).is_file():
                raise RuntimeError('Missing license/attribution: '+name)
        if digest(resources/'scrcpy-server') != SCRCPY_SHA256:
            raise RuntimeError('scrcpy server mismatch')
        bundle = {}
        allowed = {'Contents/Info.plist', 'Contents/MacOS/DesktopWeChatScanner',
                   'Contents/Resources/AppIcon.icns', 'Contents/Resources/camera-probe.jar',
                   'Contents/Resources/scrcpy-server', 'Contents/Resources/SCRCPY-LICENSE.txt',
                   'Contents/Resources/LICENSE', 'Contents/Resources/NOTICE',
                   'Contents/Resources/THIRD_PARTY.md', 'Contents/Resources/SOURCE-REVISION.txt',
                   'Contents/_CodeSignature/CodeResources'}
        for path in sorted(app.rglob('*')):
            if path.is_file():
                relative = path.relative_to(app).as_posix()
                if relative not in allowed or path.is_symlink():
                    raise RuntimeError('Unexpected bundle payload: '+relative)
                bundle[relative] = {'sha256':digest(path), 'bytes':path.stat().st_size}
        if set(bundle) != allowed:
            raise RuntimeError('Incomplete bundle')
        readme = stage/'安装说明.txt'
        readme.write_text('桌面微信扫码 0.3.2-preview.1\n\n'
                          '将桌面微信扫码.app拖到应用程序目录。仅支持Apple Silicon、macOS 14.4+。\n'
                          '本预览版仍有拖动和打开扫码卡顿。仅USB，Android 16目标环境。\n'
                          '不捆绑ADB：首次连接前从Google官方下载Mac Platform-Tools并解压，在App选择adb。\n'
                          'https://developer.android.com/tools/releases/platform-tools\n\n'
                          '此包为ad-hoc签名、未公证。若macOS阻止打开，请核对来源和校验值，按Apple官方指引操作，勿关闭Gatekeeper。\n'
                          'https://support.apple.com/102445\n\n'
                          '完整安装、隐私及开源说明：\nhttps://github.com/006IDC/desktop-wechat-scanner\n')
        shutil.copyfile(ROOT/'LICENSE', stage/'LICENSE.txt')
        zip_path = OUT/(STEM+'.zip')
        with zipfile.ZipFile(zip_path, 'x', zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
            for path in sorted(stage.rglob('*')):
                if path.is_file():
                    archive.write(path, path.relative_to(stage).as_posix())
        # DMG mounts read-only. The sole symlink is the conventional Applications shortcut.
        (stage/'Applications').symlink_to('/Applications', target_is_directory=True)
        dmg = OUT/(STEM+'.dmg')
        subprocess.run(['hdiutil', 'create', '-srcfolder', str(stage), '-volname',
                        '桌面微信扫码', '-format', 'UDZO', str(dmg)], check=True)
        subprocess.run(['hdiutil', 'verify', str(dmg)], check=True)
        mounted = temp/'mounted'; mounted.mkdir()
        subprocess.run(['hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', str(mounted), str(dmg)], check=True)
        try:
            mounted_app = mounted/APP_NAME
            verify(mounted_app)
            for name, value in bundle.items():
                if digest(mounted_app/name) != value['sha256']:
                    raise RuntimeError('DMG changed app file: '+name)
            if not (mounted/'Applications').is_symlink() or os.readlink(mounted/'Applications') != '/Applications':
                raise RuntimeError('Invalid Applications shortcut')
        finally:
            subprocess.run(['hdiutil', 'detach', str(mounted)], check=True)
        with zipfile.ZipFile(zip_path) as archive:
            if archive.testzip():
                raise RuntimeError('Release ZIP CRC failed')
            for name, value in bundle.items():
                if hashlib.sha256(archive.read(APP_NAME+'/'+name)).hexdigest() != value['sha256']:
                    raise RuntimeError('Release ZIP changed app file')
            mode = archive.getinfo(APP_NAME+'/Contents/MacOS/DesktopWeChatScanner').external_attr >> 16
            if not mode & 0o111:
                raise RuntimeError('Release ZIP lost executable permission')
        manifest = {'release':'v'+RELEASE, 'source_repository':'https://github.com/006IDC/desktop-wechat-scanner',
                    'source_commit':revision, 'architecture':'arm64', 'minimum_macos':'14.4',
                    'app_version':'0.3.2', 'app_build':'11', 'signature':'ad-hoc', 'notarized':False,
                    'bundled_adb':False, 'known_limitations':['dragging and scanner startup lag', 'USB only',
                    'first-run ADB picker and clean Mac installation not human-verified'],
                    'verification':['ZIP CRC and executable mode', 'codesign deep strict after extraction',
                    'DMG verification, read-only mount and exact bundle hashes'],
                    'bundle_files':bundle,
                    'assets':{p.name:{'sha256':digest(p), 'bytes':p.stat().st_size} for p in [zip_path,dmg]}}
        manifest_path = OUT/'release-manifest.json'
        manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2)+'\n')
        (OUT/'SHA256SUMS.txt').write_text(''.join(f'{digest(p)}  {p.name}\n' for p in [zip_path,dmg,manifest_path]))
        print('Verified release files: '+str(OUT))


if __name__ == '__main__':
    main()
