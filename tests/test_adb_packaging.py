"""Local bundle verification; never touches a device, server, config, or key."""
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = ROOT / '.local/adb-bundle'

spec = importlib.util.spec_from_file_location('bootstrap_adb', ROOT / 'scripts/bootstrap_adb.py')
bootstrap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bootstrap)

class BootstrapInputTests(unittest.TestCase):
    def test_legal_name_variants(self):
        for name in ['LICENSE', 'LICENSE-MIT', 'LICENSE_BSD', 'NOTICE.android', 'COPYING.LIB', 'Copyright.txt', 'MODULE_LICENSE_APACHE2', 'AUTHORS']:
            self.assertTrue(bootstrap.is_legal_file(name), name)
        self.assertFalse(bootstrap.is_legal_file('README.md'))

    def test_corrupt_cached_download_is_rejected_before_use(self):
        with tempfile.TemporaryDirectory() as tmp:
            previous = bootstrap.WORK
            bootstrap.WORK = Path(tmp)
            try:
                (bootstrap.WORK / 'downloads').mkdir()
                (bootstrap.WORK / 'downloads/tool.whl').write_bytes(b'changed input')
                with self.assertRaisesRegex(RuntimeError, 'SHA-256 mismatch'):
                    bootstrap.verified_download('tool.whl', 'https://files.pythonhosted.org/unused', '0' * 64)
            finally:
                bootstrap.WORK = previous

@unittest.skipUnless((BUNDLE / 'manifest.json').exists(), 'Build the ADB bundle first')
class BundledADBTests(unittest.TestCase):
    def test_archive_and_binary_integrity(self):
        manifest = json.loads((BUNDLE / 'manifest.json').read_text())
        for relative, expected in manifest['files'].items():
            self.assertEqual(hashlib.sha256((BUNDLE / relative).read_bytes()).hexdigest(), expected)
        for source in manifest['sources']:
            self.assertEqual(hashlib.sha256((BUNDLE / source['archive']).read_bytes()).hexdigest(), source['sha256'])
        self.assertTrue((BUNDLE / 'sources/build-recipe/scripts/bootstrap_adb.py').is_file())
        for relative, expected in manifest['license_documents'].items():
            self.assertEqual(hashlib.sha256((BUNDLE / relative).read_bytes()).hexdigest(), expected)
        for relative in manifest['license_coverage'].values():
            self.assertGreater((BUNDLE / relative).stat().st_size, 0)
        for tool in manifest['build_tool_inputs']:
            self.assertTrue(tool['url'].startswith('https://files.pythonhosted.org/'))
            self.assertEqual(hashlib.sha256((ROOT / '.local/adb-build/downloads' / tool['wheel']).read_bytes()).hexdigest(), tool['sha256'])

    def test_relocated_bundle_runs_without_homebrew_or_host_adb(self):
        with tempfile.TemporaryDirectory(prefix='adb-portability-') as tmp:
            dest = Path(tmp) / 'Resources/adb'
            shutil.copytree(BUNDLE / 'bin', dest / 'bin')
            shutil.copytree(BUNDLE / 'lib', dest / 'lib')
            # version is a client-only command and does not initialize a server.
            result = subprocess.run([str(dest / 'bin/adb'), 'version'], check=True, text=True,
                                    capture_output=True, env={'PATH': '/usr/bin:/bin'})
            self.assertIn('Android Debug Bridge version 1.0.41', result.stdout)
            for binary in (dest / 'bin/adb', dest / 'lib/libusb-1.0.0.dylib'):
                loads = subprocess.check_output(['/usr/bin/otool', '-l', str(binary)], text=True)
                self.assertNotIn(str(ROOT), '\n'.join(loads.splitlines()[1:]))
                self.assertFalse(b'/Users/' in binary.read_bytes(), 'Host path found in binary')
                deps = subprocess.check_output(['/usr/bin/otool', '-L', str(binary)], text=True)
                for line in deps.splitlines()[1:]:
                    path = line.strip().split(' (')[0]
                    self.assertTrue(path.startswith(('/usr/lib/', '/System/Library/', '@loader_path/')), path)
                subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(binary)], check=True)

if __name__ == '__main__':
    unittest.main()
