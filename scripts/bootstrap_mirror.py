#!/usr/bin/env python3
"""Fetch the pinned official scrcpy server used by the native Mac mirror."""
import hashlib
from pathlib import Path
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / '.tools/scrcpy/scrcpy-server-v5.0.1'
URL = 'https://github.com/Genymobile/scrcpy/releases/download/v5.0.1/scrcpy-server-v5.0.1'
# Genymobile/scrcpy v5.0.1 install_release.sh, not a third-party checksum.
SHA256 = '764eb6f79811d5211fe9df341120882ba9994c7a61b897d7bf3fb662e53bc536'

def digest(path: Path) -> str:
    hash_ = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            hash_.update(chunk)
    return hash_.hexdigest()

DEST.parent.mkdir(parents=True, exist_ok=True)
if DEST.exists() and digest(DEST) == SHA256:
    print(f'Verified: {DEST}')
else:
    with tempfile.NamedTemporaryFile(prefix='scrcpy-v5.0.1-', dir=DEST.parent, delete=False) as stream:
        temporary = Path(stream.name)
    try:
        with urllib.request.urlopen(URL, timeout=45) as source, temporary.open('wb') as output:
            for chunk in iter(lambda: source.read(1024 * 1024), b''):
                output.write(chunk)
        if digest(temporary) != SHA256:
            raise RuntimeError('Official scrcpy server SHA-256 mismatch')
        temporary.replace(DEST)
        print(f'Verified: {DEST}')
    finally:
        temporary.unlink(missing_ok=True)
