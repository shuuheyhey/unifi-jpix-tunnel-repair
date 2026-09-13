from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class LauncherTests(unittest.TestCase):
    def test_absolute_and_relative_symlinks_find_release_package(self):
        source = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            release = root / 'releases/v2.0.0'
            (release / 'bin').mkdir(parents=True)
            shutil.copy2(source / 'bin/unifi-jpix', release / 'bin/unifi-jpix')
            shutil.copytree(source / 'src', release / 'src')
            (root / 'current').symlink_to('releases/v2.0.0')
            (root / 'command').symlink_to(root / 'current/bin/unifi-jpix')
            result = subprocess.run([str(root / 'command'), '--help'], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('reconcile', result.stdout)


if __name__ == '__main__':
    unittest.main()
