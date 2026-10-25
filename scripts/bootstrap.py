#!/usr/bin/env python3
"""Download pinned official tools into this experiment only."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import hashlib
import subprocess
import tarfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / '.tools'
ASSETS = [
    ('platform', 'https://dl.google.com/android/repository/platform-36_r02.zip', 'sha1', '2c1a80dd4d9f7d0e6dd336ec603d9b5c55a6f576', 'sdk-platform'),
    ('build-tools', 'https://dl.google.com/android/repository/build-tools_r36_macosx.zip', 'sha1', '199ae0047ee61e842f8ee0c6d3918e44fb9a1f83', 'sdk-build'),
    ('jdk', 'https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.13%2B9/OpenJDK21U-jdk_aarch64_mac_hotspot_21.0.13_9.tar.gz', 'sha256', 'bf036b35b071bfb2f54f2c0af8ee8d88afa95ee6eb3dce02c0f94cfc2524d04a', 'jdk'),
]

def install(asset):
    name, url, algorithm, digest, directory = asset
    downloads = TOOLS / 'downloads'
    downloads.mkdir(parents=True, exist_ok=True)
    archive = downloads / url.rsplit('/', 1)[-1]
    if not archive.exists():
        subprocess.run(['curl', '-fsSL', '--connect-timeout', '20', '--max-time', '300', '--retry', '2', url, '-o', str(archive)], check=True)
    actual = hashlib.file_digest(archive.open('rb'), algorithm).hexdigest()
    if actual != digest:
        raise RuntimeError(f'{name}: integrity check failed; archive retained for inspection')
    dest = TOOLS / directory
    dest.mkdir(parents=True, exist_ok=True)
    marker = dest / '.verified'
    if marker.exists() and marker.read_text() == digest:
        print(f'{name}: verified tools already available', flush=True)
        return
    if archive.name.endswith('.zip'):
        with zipfile.ZipFile(archive) as z:
            for member in z.infolist():
                target = (dest / member.filename).resolve()
                if not target.is_relative_to(dest.resolve()):
                    raise RuntimeError('Unsafe archive path')
                z.extract(member, dest)
                mode = (member.external_attr >> 16) & 0o777
                if mode and not member.is_dir():
                    target.chmod(mode)
    else:
        with tarfile.open(archive) as tar:
            tar.extractall(dest, filter='data')
    marker.write_text(digest)
    print(f'{name}: downloaded, checksum verified, extracted', flush=True)

if __name__ == '__main__':
    with ThreadPoolExecutor(max_workers=4) as pool:
        list(pool.map(install, ASSETS))
