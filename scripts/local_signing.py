#!/usr/bin/env python3
"""Create/reopen a project-only code-signing identity without keychain UI."""
import os
from pathlib import Path
import secrets
import stat
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
IDENTITY = ROOT / '.local/signing/identity'
KEYCHAIN = IDENTITY / 'signing.keychain-db'
PASSWORD = IDENTITY / 'password'
HELPER = ROOT / '.local/signing/local-signing-helper'
MARKER = IDENTITY / 'fingerprint'


def _run(command: list[str]) -> None:
    subprocess.run(command, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)


def fingerprint() -> str:
    """Return the local certificate SHA-1 fingerprint for codesign --sign."""
    IDENTITY.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if IDENTITY.parent.is_symlink():
        raise RuntimeError('Local signing directory must not be a symlink')
    os.chmod(IDENTITY.parent, 0o700)
    IDENTITY.mkdir(parents=True, exist_ok=True, mode=0o700)
    if any(path.is_symlink() for path in (IDENTITY, KEYCHAIN, PASSWORD, MARKER)):
        raise RuntimeError('Local signing path must not be a symlink')
    os.chmod(IDENTITY, 0o700)
    if MARKER.exists() and not KEYCHAIN.exists():
        raise RuntimeError('Local signing keychain is missing; cannot preserve identity')
    if KEYCHAIN.exists() and not MARKER.exists():
        raise RuntimeError('Untracked local signing keychain; refusing to import another identity')
    if KEYCHAIN.exists() and not PASSWORD.exists():
        raise RuntimeError('Local keychain password is missing; preserve identity for diagnosis')
    if PASSWORD.exists() and stat.S_IMODE(PASSWORD.stat().st_mode) != 0o600:
        raise RuntimeError('Local keychain password file must be mode 600')
    expected_fingerprint = None
    if MARKER.exists():
        if stat.S_IMODE(MARKER.stat().st_mode) != 0o600:
            raise RuntimeError('Local signing fingerprint file must be mode 600')
        marker_contents = MARKER.read_text()
        expected_fingerprint = marker_contents.removesuffix('\n')
        if (marker_contents != expected_fingerprint + '\n'
                or len(expected_fingerprint) != 40
                or not all(char in '0123456789ABCDEF' for char in expected_fingerprint)):
            raise RuntimeError('Local signing fingerprint file is invalid')
    if not HELPER.exists() or HELPER.stat().st_mtime < (ROOT / 'scripts/local_signing.swift').stat().st_mtime:
        _run(['swiftc', '-swift-version', '5', '-module-cache-path', str(ROOT / '.local/swift-cache'),
              str(ROOT / 'scripts/local_signing.swift'), '-o', str(HELPER)])
    if not MARKER.exists():
        if not PASSWORD.exists():
            fd = os.open(PASSWORD, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, 'w') as stream:
                stream.write(secrets.token_urlsafe(48) + '\n')
        with tempfile.TemporaryDirectory(prefix='006idc-sign-', dir=IDENTITY) as temporary:
            folder = Path(temporary)
            os.chmod(folder, 0o700)
            key, cert, bundle = (folder / name for name in ('key.pem', 'cert.pem', 'identity.p12'))
            previous_umask = os.umask(0o077)
            try:
                _run(['openssl', 'req', '-new', '-x509', '-newkey', 'rsa:3072', '-nodes',
                      '-keyout', str(key), '-out', str(cert), '-days', '3650',
                      '-subj', '/CN=006IDC Desktop WeChat Scanner Local/O=006IDC',
                      '-addext', 'basicConstraints=critical,CA:TRUE',
                      '-addext', 'keyUsage=critical,digitalSignature,keyCertSign',
                      '-addext', 'extendedKeyUsage=codeSigning'])
                _run(['openssl', 'pkcs12', '-export', '-inkey', str(key), '-in', str(cert),
                      '-out', str(bundle), '-passout', f'file:{PASSWORD}',
                      '-keypbe', 'PBE-SHA1-3DES', '-certpbe', 'PBE-SHA1-3DES', '-macalg', 'sha1'])
            finally:
                os.umask(previous_umask)
            output = subprocess.check_output([str(HELPER), 'create', str(KEYCHAIN), str(PASSWORD), str(bundle)], text=True).strip()
            if len(output) != 40 or not all(char in '0123456789ABCDEF' for char in output):
                raise RuntimeError('Local signing helper returned an invalid fingerprint')
            MARKER.write_text(output + '\n')
            os.chmod(MARKER, 0o600)
    else:
        output = subprocess.check_output([str(HELPER), 'open', str(KEYCHAIN), str(PASSWORD), '-'], text=True).strip()
    if len(output) != 40 or not all(char in '0123456789ABCDEF' for char in output):
        raise RuntimeError('Local signing helper returned an invalid fingerprint')
    if expected_fingerprint is not None and expected_fingerprint != output:
        raise RuntimeError('Local signing identity fingerprint changed; refusing to sign')
    os.chmod(KEYCHAIN, 0o600)
    return output


if __name__ == '__main__':
    print(fingerprint())
