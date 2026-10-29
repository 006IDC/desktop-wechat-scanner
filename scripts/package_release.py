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
RELEASE = '0.4.0-preview.5'
APP_BUILD = '43'
APP_NAME = 'MiraDroid.app'
STEM = f'MiraDroid-{RELEASE}-macOS-arm64'
OUT = ROOT / 'build/release' / RELEASE
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
    if run('git', 'status', '--porcelain'):
        raise RuntimeError('Commit source changes before packaging')
    with tempfile.TemporaryDirectory(prefix='wechat-release-') as temporary:
        temp = Path(temporary)
        stage = temp/'stage'; stage.mkdir()
        extract_checked(ROOT/'build/MiraDroid-本机签名.zip', stage)
        app = stage/APP_NAME
        verify(app)
        # Packaging never creates/opens a signing keychain. Verify the public
        # certificate embedded in this ZIP against the existing identity marker.
        from local_signing import MARKER as marker
        marker_mode = marker.lstat().st_mode
        if not stat.S_ISREG(marker_mode) or stat.S_IMODE(marker_mode) != 0o600:
            raise RuntimeError('Signing identity marker must be a regular mode-600 file')
        marker_contents = marker.read_text()
        expected_identity = marker_contents.removesuffix('\n')
        if (marker_contents != expected_identity + '\n' or len(expected_identity) != 40
                or any(c not in '0123456789ABCDEF' for c in expected_identity)):
            raise RuntimeError('Invalid persistent signing identity marker')
        cert_prefix = temp/'release-certificate-'
        subprocess.run(['codesign', '-d', '--extract-certificates='+str(cert_prefix), str(app)], check=True)
        certificate = Path(str(cert_prefix)+'0').read_bytes()
        if hashlib.sha1(certificate).hexdigest().upper() != expected_identity:
            raise RuntimeError('Release certificate differs from persistent identity')
        requirement = 'identifier "com.idc006.DesktopWeChatScanner" and certificate root = H"'+expected_identity+'"'
        subprocess.run(['codesign', '--verify', '--strict', '-R='+requirement, str(app)], check=True)
        resources = app/'Contents/Resources'
        if not (resources/'adb/bin/adb').is_file():
            raise RuntimeError('Missing bundled ADB')
        adb_manifest = json.loads((resources/'adb/manifest.json').read_text())
        for relative, expected in adb_manifest['files'].items():
            if digest(resources/'adb'/relative) != expected:
                raise RuntimeError('Bundled ADB binary differs from source build')
        for source in adb_manifest['sources']:
            if digest(resources/'adb'/source['archive']) != source['sha256']:
                raise RuntimeError('Bundled ADB corresponding source differs')
        if (resources/'SOURCE-REVISION.txt').read_text().strip() != revision:
            raise RuntimeError('App source revision does not match current commit')
        info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
        if (info['CFBundleShortVersionString'], info['CFBundleVersion'], info['DesktopScannerRelease']) != ('0.4.0', APP_BUILD, RELEASE):
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
        for source in (ROOT/'.local/adb-bundle').rglob('*'):
            if source.is_file() and not source.is_symlink():
                allowed.add('Contents/Resources/adb/' + source.relative_to(ROOT/'.local/adb-bundle').as_posix())
        for path in sorted(app.rglob('*')):
            if path.is_file():
                relative = path.relative_to(app).as_posix()
                if relative not in allowed or path.is_symlink():
                    raise RuntimeError('Unexpected bundle payload: '+relative)
                bundle[relative] = {'sha256':digest(path), 'bytes':path.stat().st_size}
        if set(bundle) != allowed:
            raise RuntimeError('Incomplete bundle')
        readme = stage/'安装说明.txt'
        readme.write_text('MiraDroid '+RELEASE+'\n\n'
                          '将MiraDroid.app拖到应用程序目录。仅支持Apple Silicon、macOS 14.4+。\n'
                          '预览版：Android 16目标环境；无线配对和应用独立窗口有设备兼容性限制。\n'
                          '已内置开源ADB，无需额外安装。无线连接需在手机允许配对，配对码只填入App。\n'
                          '配对会保留此Mac的调试信任，断开App不会撤销。请在手机无线调试的已配对设备中忘记此Mac以撤销。\n\n'
                          '此包使用维护者持续保留的自签代码签名身份，未经过 Apple Developer ID 签名或公证。\n'
                          '由旧 ad-hoc 版本迁移时仍需一次录屏授权；相同身份后续更新不再因二进制变化而改变代码身份。\n'
                          '若macOS阻止打开，请核对来源和校验值，按Apple官方指引操作，勿关闭Gatekeeper。\n'
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
                        'MiraDroid', '-format', 'UDZO', str(dmg)], check=True)
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
                    'app_version':'0.4.0', 'app_build':APP_BUILD, 'signature':'persistent self-signed', 'notarized':False,
                    'signing_certificate_sha256':hashlib.sha256(certificate).hexdigest(),
                    'bundled_adb':True, 'adb_source_version':'37.0.0-android-tools',
                    'known_limitations':['WeChat recognition still requires a phone round trip; local camera aperture bypasses it only for desktop preview', 'app pairing UI not yet verified',
                    'remembered wireless device reconnect verified in App; changed-port Bonjour recovery not yet verified',
                    'migration from previous ad-hoc builds requires screen-recording consent; same-certificate permission retention verified locally across builds 16, 18 and 19; new Mac installation remains unverified',
                    'independent app display support varies by Android app and device',
                    'interactive drag and clean Mac installation not human-verified'],
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
