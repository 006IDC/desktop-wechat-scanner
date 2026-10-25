#!/usr/bin/env python3
"""Build a pinned open-source macOS arm64 ADB bundle without touching host ADB.

Never runs devices, start-server, pair, connect or any command reading ADB keys.
All downloads, compiler outputs and Python build tools stay in .local/adb-build.
"""
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / '.local/adb-build'
BUNDLE = ROOT / '.local/adb-bundle'
RECIPE = ROOT / 'third_party/adb'
SOURCES = {
    'googletest-1.17.0': ('https://github.com/google/googletest/archive/refs/tags/v1.17.0.tar.gz', '65fab701d9829d38cb77c14acdc431d2108bfdbf8979e40eb8ae567edf10b27c'),
    'android-tools-37.0.0': ('https://github.com/nmeum/android-tools/releases/download/37.0.0/android-tools-37.0.0.tar.xz', '2725d09f892a3a38e534429f47a321f58ecf6a3169caa42c915fb2cb7d46be0e'),
    'protobuf-3.21.12': ('https://github.com/protocolbuffers/protobuf/releases/download/v21.12/protobuf-cpp-3.21.12.tar.gz', '4eab9b524aa5913c6fffb20b2a8abf5ef7f95a80bc0701f3a6dbb4c607f73460'),
    'brotli-1.2.0': ('https://github.com/google/brotli/archive/refs/tags/v1.2.0.tar.gz', '816c96e8e8f193b40151dad7e8ff37b1221d019dbcb9c35cd3fadbfe6477dfec'),
    'lz4-1.10.0': ('https://github.com/lz4/lz4/archive/refs/tags/v1.10.0.tar.gz', '537512904744b35e232912055ccf8ec66d768639ff3abe5788d90d792ec5f48b'),
    'zstd-1.5.7': ('https://github.com/facebook/zstd/archive/refs/tags/v1.5.7.tar.gz', '37d7284556b20954e56e1ca85b80226768902e2edabd3b649e9e72c0c9012ee3'),
}

# PyPI's official release JSON identifies these py3-none universal2 wheels;
# both support arm64 and do not depend on a CPython ABI-specific wheel.
BUILD_TOOL_WHEELS = {
    'cmake': ('https://files.pythonhosted.org/packages/24/79/1bf4009d7ef16d62e0b92ddb78efeda830ca5903149abf9dc01d270c3d4e/cmake-4.1.3-py3-none-macosx_10_10_universal2.whl', '3b6b25ce8fecc768881b36a1dfbca0013adac10a299c73e24cf4cbb99e4c37d6'),
    'ninja': ('https://files.pythonhosted.org/packages/3c/74/d02409ed2aa865e051b7edda22ad416a39d81a84980f544f8de717cab133/ninja-1.13.0-py3-none-macosx_10_9_universal2.whl', 'fa2a8bfc62e31b08f83127d1613d10821775a0eb334197154c4d6067b7068ff1'),
}

# Standalone notices for every linked non-system component that supplies one.
# libziparchive/core helper source-file copyright headers remain in the exact
# corresponding source archive; the full Apache-2.0 text is also retained here.
LICENSE_COVERAGE = {
    'android-tools-and-AOSP-helpers': 'android-tools-37.0.0/LICENSE',
    'adb': 'android-tools-37.0.0/vendor/adb/NOTICE',
    'libbase': 'android-tools-37.0.0/vendor/libbase/NOTICE',
    'libcutils': 'android-tools-37.0.0/vendor/core/libcutils/NOTICE',
    'liblog': 'android-tools-37.0.0/vendor/logging/liblog/NOTICE',
    'libusb': 'android-tools-37.0.0/vendor/libusb/COPYING',
    'fmt': 'android-tools-37.0.0/vendor/fmtlib/LICENSE',
    'BoringSSL': 'android-tools-37.0.0/vendor/boringssl/LICENSE',
    'protobuf': 'protobuf-3.21.12/LICENSE',
    'brotli': 'brotli-1.2.0/LICENSE',
    'lz4': 'lz4-1.10.0/lib/LICENSE',
    'zstd': 'zstd-1.5.7/LICENSE',
    'googletest-header': 'googletest-1.17.0/LICENSE',
}

def is_legal_file(name):
    return bool(re.match(r'^(?:(?:licen[cs]e|copying|copyright|notice|authors)(?:$|[._-])|module_license_)', name, re.IGNORECASE))

def verified_download(filename, url, sha):
    archive = WORK / 'downloads' / filename
    archive.parent.mkdir(parents=True, exist_ok=True)
    if not archive.exists():
        partial = archive.with_suffix(archive.suffix + '.partial')
        with urllib.request.urlopen(url, timeout=60) as src, partial.open('wb') as dst:
            shutil.copyfileobj(src, dst)
        if digest(partial) != sha:
            raise RuntimeError(f'SHA-256 mismatch for {filename}; refusing use')
        partial.replace(archive)
    if digest(archive) != sha:
        raise RuntimeError(f'SHA-256 mismatch for cached {filename}')
    return archive

def digest(path):
    with path.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()

def run(*args, capture=False):
    return subprocess.run([str(a) for a in args], check=True, text=True,
                          stdout=subprocess.PIPE if capture else None).stdout

def fetch(name, url, sha):
    suffix = '.tar.xz' if url.endswith('.xz') else '.tar.gz'
    archive = verified_download(name + suffix, url, sha)
    source = WORK / name
    if not source.exists():
        with tarfile.open(archive) as tar:
            tar.extractall(WORK, filter='data')
    if not source.is_dir():
        raise RuntimeError(f'Unexpected source root: {name}')
    return source, archive

def main():
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise SystemExit('Bundled ADB build currently supports macOS arm64 only')
    WORK.mkdir(parents=True, exist_ok=True)
    toolpython = WORK / 'venv/bin/python3'
    if not toolpython.exists():
        run(sys.executable, '-m', 'venv', WORK / 'venv')
    cmake = WORK / 'venv/bin/cmake'
    ninja = WORK / 'venv/bin/ninja'
    wheels = [verified_download(url.rsplit('/', 1)[-1], url, sha) for url, sha in BUILD_TOOL_WHEELS.values()]
    # Reinstall the verified bytes even when an existing tool reports the same
    # version, so a prior editable/local installation cannot change the input.
    run(toolpython, '-m', 'pip', 'install', '--no-index', '--no-deps', '--no-cache-dir', '--force-reinstall', *wheels)
    if 'cmake version 4.1.3' not in run(cmake, '--version', capture=True):
        raise RuntimeError('Expected project-local CMake 4.1.3')
    if not run(ninja, '--version', capture=True).strip().startswith('1.13.0'):
        raise RuntimeError('Expected project-local Ninja 1.13.0')
    sources = {name: fetch(name, *spec) for name, spec in SOURCES.items()}
    prefix = WORK / 'prefix'
    common = ['-G', 'Ninja', f'-DCMAKE_MAKE_PROGRAM={ninja}', '-DCMAKE_BUILD_TYPE=Release',
              '-DCMAKE_OSX_ARCHITECTURES=arm64', '-DCMAKE_OSX_DEPLOYMENT_TARGET=14.4',
              '-DCMAKE_POLICY_VERSION_MINIMUM=3.5', f'-DCMAKE_INSTALL_PREFIX={prefix}',
              '-DBUILD_SHARED_LIBS=OFF', '-DBUILD_TESTING=OFF', '-DCMAKE_SKIP_RPATH=ON',
              f'-DCMAKE_C_FLAGS=-ffile-prefix-map={WORK}=adb-source',
              f'-DCMAKE_CXX_FLAGS=-ffile-prefix-map={WORK}=adb-source']
    def build(name, sub='', flags=(), target='install'):
        source = sources[name][0] / sub
        output = WORK / ('build-' + name)
        run(cmake, '-S', source, '-B', output, *common, *flags)
        run(cmake, '--build', output, '--target', target, '--parallel', '6')
        return output
    build('protobuf-3.21.12', flags=['-Dprotobuf_BUILD_TESTS=OFF', '-Dprotobuf_WITH_ZLIB=OFF'])
    build('brotli-1.2.0', flags=['-DBROTLI_DISABLE_TESTS=ON'])
    build('lz4-1.10.0', 'build/cmake', ['-DLZ4_BUILD_CLI=OFF', '-DLZ4_BUILD_LEGACY_LZ4C=OFF'])
    build('zstd-1.5.7', 'build/cmake', ['-DZSTD_BUILD_PROGRAMS=OFF', '-DZSTD_BUILD_TESTS=OFF', '-DZSTD_BUILD_SHARED=OFF'])
    android = sources['android-tools-37.0.0'][0]
    shutil.copy2(RECIPE / 'vendor.CMakeLists.txt', android / 'vendor/CMakeLists.txt')
    libusb_cmake = android / 'vendor/CMakeLists.libusb.txt'
    libusb_cmake.write_text(libusb_cmake.read_text().replace('add_library(android_tools_libusb STATIC', 'add_library(android_tools_libusb SHARED'))
    output = build('android-tools-37.0.0', flags=[f'-DCMAKE_PREFIX_PATH={prefix}', f'-DADB_DEPS_PREFIX={prefix}',
                   f'-DADB_RECIPE_DIR={RECIPE}', f'-DADB_GTEST_INCLUDE={sources["googletest-1.17.0"][0] / "googletest/include"}', '-DANDROID_TOOLS_PATCH_VENDOR=OFF'], target='adb')
    (BUNDLE / 'bin').mkdir(parents=True, exist_ok=True)
    (BUNDLE / 'lib').mkdir(exist_ok=True)
    shutil.copy2(output / 'vendor/adb', BUNDLE / 'bin/adb')
    dylib = next((output / 'vendor').glob('libusb-1.0.0.5.0.dylib'))
    shutil.copy2(dylib, BUNDLE / 'lib/libusb-1.0.0.dylib')
    adb = BUNDLE / 'bin/adb'
    usb = BUNDLE / 'lib/libusb-1.0.0.dylib'
    old = next(line.strip().split(' (')[0] for line in run('otool', '-L', adb, capture=True).splitlines()[1:] if 'libusb-' in line)
    run('install_name_tool', '-change', old, '@loader_path/../lib/libusb-1.0.0.dylib', adb)
    run('install_name_tool', '-id', '@loader_path/libusb-1.0.0.dylib', usb)
    for binary in (usb, adb):
        run('/usr/bin/strip', '-S', '-x', binary)
        run('codesign', '--force', '--sign', '-', binary)
        run('codesign', '--verify', '--strict', binary)
        if str(ROOT) in '\n'.join(run('otool', '-l', binary, capture=True).splitlines()[1:]) or b'/Users/' in binary.read_bytes():
            raise RuntimeError('Host build path leaked into Mach-O load commands')
        for line in run('otool', '-L', binary, capture=True).splitlines()[1:]:
            dep = line.strip().split(' (')[0]
            if not dep.startswith(('/usr/lib/', '/System/Library/', '@loader_path/')):
                raise RuntimeError(f'Nonportable runtime dependency: {dep}')
    # Keep the exact complete corresponding sources, not merely a download offer.
    for name, (source, archive) in sources.items():
        source_dest = BUNDLE / 'sources' / archive.name
        source_dest.parent.mkdir(exist_ok=True)
        shutil.copy2(archive, source_dest)
        for path in source.rglob('*'):
            if path.is_file() and is_legal_file(path.name):
                dest = BUNDLE / 'licenses' / name / path.relative_to(source)
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, dest)
    for component, relative in LICENSE_COVERAGE.items():
        if not (BUNDLE / 'licenses' / relative).is_file() or not (BUNDLE / 'licenses' / relative).stat().st_size:
            raise RuntimeError(f'Missing license/notice for linked component {component}: {relative}')
    recipe_dest = BUNDLE / 'sources/build-recipe'
    recipe_dest.mkdir(parents=True, exist_ok=True)
    (recipe_dest / 'scripts').mkdir(exist_ok=True)
    shutil.copy2(__file__, recipe_dest / 'scripts/bootstrap_adb.py')
    (recipe_dest / 'third_party/adb').mkdir(parents=True, exist_ok=True)
    for path in RECIPE.iterdir():
        if path.is_file(): shutil.copy2(path, recipe_dest / 'third_party/adb' / path.name)
    version = run(adb, 'version', capture=True)
    # ADB prints its installed absolute path; remove that host-specific line.
    version = '\n'.join(line for line in version.splitlines() if not line.startswith('Installed as '))
    manifest = {'schema': 1, 'platform': 'macOS-arm64', 'deployment_target': '14.4',
        'adb_version': version, 'build_tools': {'cmake': '4.1.3', 'ninja': '1.13.0',
        'clang': run('clang', '--version', capture=True).splitlines()[0], 'sdk': run('xcrun', '--show-sdk-version', capture=True).strip()},
        'build_tool_inputs': [{'name': name, 'url': url, 'sha256': sha, 'wheel': url.rsplit('/', 1)[-1], 'metadata': f'https://pypi.org/pypi/{name}/{"4.1.3" if name == "cmake" else "1.13.0"}/json'} for name, (url, sha) in BUILD_TOOL_WHEELS.items()],
        'license_coverage': {component: 'licenses/' + relative for component, relative in LICENSE_COVERAGE.items()},
        'license_documents': {str(p.relative_to(BUNDLE)): digest(p) for p in sorted((BUNDLE / 'licenses').rglob('*')) if p.is_file()},
        'bundled_components': {'libusb': '1.0.29 (android-tools vendored)', 'fmt': '12.0.0 (android-tools vendored)', 'boringssl_revision': 'd32c35e573fc9c8dbe0436805cd557065892de4c'},
        'features': {'usb': True, 'explicit_endpoint_pairing': True, 'mdns_discovery': False},
        'sources': [{'name': n, 'url': u, 'sha256': s, 'archive': 'sources/' + sources[n][1].name} for n, (u, s) in SOURCES.items()],
        'files': {str(p.relative_to(BUNDLE)): digest(p) for p in (adb, usb)}}
    (BUNDLE / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    shutil.copy2(RECIPE / 'README.md', BUNDLE / 'README.md')
    print(version)
    print('Verified portable bundle:', BUNDLE)

if __name__ == '__main__':
    main()
