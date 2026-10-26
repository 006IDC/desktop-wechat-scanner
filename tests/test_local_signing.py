#!/usr/bin/env python3
"""Isolated code-signing behavior test; never operates on installed apps."""
from contextlib import contextmanager
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from local_signing import KEYCHAIN, fingerprint  # noqa: E402


def call(*args: str) -> None:
    result = subprocess.run(args, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    if result.returncode:
        raise RuntimeError(f'{args[0]} failed: {result.stderr.strip()}')


def app(folder: Path, name: str, message: str) -> Path:
    bundle = folder / f'{name}.app'
    contents = bundle / 'Contents'
    binary = contents / 'MacOS'
    binary.mkdir(parents=True)
    with (contents / 'Info.plist').open('wb') as stream:
        plistlib.dump({'CFBundleIdentifier': 'com.idc006.SigningSyntheticTest',
                       'CFBundleExecutable': 'Synthetic', 'CFBundlePackageType': 'APPL'}, stream)
    source = folder / f'{name}.c'
    source.write_text(f'#include <stdio.h>\nint main(void) {{ puts("{message}"); return 0; }}\n')
    call('clang', str(source), '-o', str(binary / 'Synthetic'))
    return bundle


def requirement(bundle: Path) -> str:
    result = subprocess.run(['codesign', '-d', '-r', '-', str(bundle)], check=True,
                            text=True, capture_output=True)
    for line in (result.stderr + '\n' + result.stdout).splitlines():
        if line.startswith('designated => '):
            return line.removeprefix('designated => ')
    raise AssertionError(f'No designated requirement: {result.stderr} {result.stdout}')


@contextmanager
def metadata_fixture():
    """A complete fake identity for metadata unit tests, separate from .local/signing."""
    with tempfile.TemporaryDirectory(prefix='006idc-signing-metadata-') as temp:
        identity = Path(temp) / 'identity'
        identity.mkdir(mode=0o700)
        keychain = identity / 'signing.keychain-db'
        password = identity / 'password'
        marker = identity / 'fingerprint'
        helper = Path(temp) / 'helper'
        keychain.write_bytes(b'synthetic keychain placeholder')
        password.write_text('synthetic password\n')
        marker.write_text('A' * 40 + '\n')
        helper.write_text('synthetic helper placeholder\n')
        for path in (keychain, password, marker):
            os.chmod(path, 0o600)
        os.utime(helper, (2_000_000_000, 2_000_000_000))
        with mock.patch.multiple('local_signing', IDENTITY=identity, KEYCHAIN=keychain,
                                 PASSWORD=password, MARKER=marker, HELPER=helper):
            yield password, marker, keychain, helper


class LocalSigningTest(unittest.TestCase):
    def test_existing_identity_rejects_exposed_keychain(self) -> None:
        with metadata_fixture() as (_, _, keychain, _):
            os.chmod(keychain, 0o644)
            with self.assertRaisesRegex(RuntimeError, 'keychain file must be mode 600'):
                fingerprint()

    def test_existing_identity_rejects_exposed_password(self) -> None:
        with metadata_fixture() as (password, _, _, _):
            os.chmod(password, 0o644)
            with self.assertRaisesRegex(RuntimeError, 'password file must be mode 600'):
                fingerprint()

    def test_existing_identity_rejects_bad_marker(self) -> None:
        with metadata_fixture() as (_, marker, _, _):
            marker.write_text('invalid\n')
            with self.assertRaisesRegex(RuntimeError, 'fingerprint file is invalid'):
                fingerprint()
            marker.write_text('A' * 40 + '\n')
            os.chmod(marker, 0o644)
            with self.assertRaisesRegex(RuntimeError, 'fingerprint file must be mode 600'):
                fingerprint()

    def test_existing_identity_fingerprint_mismatch_is_rejected(self) -> None:
        with metadata_fixture() as (password, _, keychain, helper):
            with mock.patch('local_signing.subprocess.check_output', return_value='B' * 40) as check_output:
                with self.assertRaisesRegex(RuntimeError, 'fingerprint changed'):
                    fingerprint()
                check_output.assert_called_once_with(
                    [str(helper), 'open', str(keychain), str(password), '-'], text=True)

    # Explicit integration test: uses the persistent identity only when opted in.
    @unittest.skipUnless(os.environ.get('RUN_LOCAL_SIGNING_INTEGRATION') == '1',
                         'set RUN_LOCAL_SIGNING_INTEGRATION=1 to use the persistent local identity')
    def test_stable_designated_requirement_and_other_certificate_rejected(self) -> None:
        identity = fingerprint()
        with tempfile.TemporaryDirectory(prefix='006idc-signing-test-') as temp:
            folder = Path(temp)
            first = app(folder, 'first', 'one')
            second = app(folder, 'second', 'two')
            for bundle in (first, second):
                call('codesign', '--force', '--keychain', str(KEYCHAIN), '--sign', identity,
                     '--identifier', 'com.idc006.SigningSyntheticTest', str(bundle))
                call('codesign', '--verify', '--strict', str(bundle))
            old_requirement = requirement(first)
            self.assertEqual(old_requirement, requirement(second))
            self.assertIn('certificate', old_requirement)
            call('codesign', '--verify', '--strict', '-R=' + old_requirement, str(second))

            other = folder / 'other'
            other.mkdir(mode=0o700)
            password = other / 'password'
            fd = os.open(password, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, 'w') as stream:
                stream.write(os.urandom(32).hex() + '\n')
            key, cert, p12, keychain = (other / name for name in ('key.pem', 'cert.pem', 'other.p12', 'other.keychain-db'))
            call('openssl', 'req', '-new', '-x509', '-newkey', 'rsa:3072', '-nodes',
                 '-keyout', str(key), '-out', str(cert), '-days', '3650',
                 '-subj', '/CN=006IDC Alternate Synthetic Signing/O=006IDC',
                 '-addext', 'basicConstraints=critical,CA:TRUE',
                 '-addext', 'keyUsage=critical,digitalSignature,keyCertSign',
                 '-addext', 'extendedKeyUsage=codeSigning')
            call('openssl', 'pkcs12', '-export', '-inkey', str(key), '-in', str(cert),
                 '-out', str(p12), '-passout', f'file:{password}',
                 '-keypbe', 'PBE-SHA1-3DES', '-certpbe', 'PBE-SHA1-3DES', '-macalg', 'sha1')
            for private in (key, p12):
                os.chmod(private, 0o600)
            helper = ROOT / '.local/signing/local-signing-helper'
            other_identity = subprocess.check_output([str(helper), 'create', str(keychain), str(password), str(p12)], text=True).strip()
            os.chmod(keychain, 0o600)
            third = app(folder, 'third', 'three')
            call('codesign', '--force', '--keychain', str(keychain), '--sign', other_identity,
                 '--identifier', 'com.idc006.SigningSyntheticTest', str(third))
            call('codesign', '--verify', '--strict', str(third))
            self.assertNotEqual(old_requirement, requirement(third))
            negative = subprocess.run(['codesign', '--verify', '--strict',
                                       '-R=' + old_requirement, str(third)], capture_output=True)
            self.assertNotEqual(negative.returncode, 0)


if __name__ == '__main__':
    unittest.main()
