from __future__ import annotations

import hashlib
import io
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

from unifi_jpix.release import ReleaseError, ReleaseManager


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.manager = ReleaseManager(self.root)

    def test_manifest_must_cover_every_release_file(self):
        release = self.root / "release"
        release.mkdir()
        (release / "payload").write_text("ok", encoding="utf-8")
        manifest = release / "release-manifest.json"
        manifest.write_text(json.dumps({
            "schema": 1,
            "version": "v2.0.0",
            "files": {"payload": hashlib.sha256(b"ok").hexdigest()},
        }), encoding="utf-8")
        self.manager._verify_manifest(release, manifest, "v2.0.0")
        (release / "unlisted").write_text("not covered", encoding="utf-8")
        with self.assertRaises(ReleaseError):
            self.manager._verify_manifest(release, manifest, "v2.0.0")

    def test_archive_rejects_path_traversal(self):
        archive_path = self.root / "bad.tar.gz"
        with tarfile.open(archive_path, "w:gz") as archive:
            entry = tarfile.TarInfo("../escape")
            entry.size = 1
            archive.addfile(entry, io.BytesIO(b"x"))
        destination = self.root / "extract"
        destination.mkdir()
        with tarfile.open(archive_path, "r:gz") as archive, self.assertRaises(ReleaseError):
            self.manager._safe_extract(archive, destination)
        self.assertFalse((self.root / "escape").exists())

    @unittest.skipUnless(shutil.which("openssl"), "openssl is required")
    def test_detached_checksum_signature(self):
        private = self.root / "private.pem"
        public = self.root / "public.pem"
        checksum = self.root / "release.sha256"
        signature = self.root / "release.sha256.sig"
        subprocess.run(["openssl", "genrsa", "-out", str(private), "2048"], check=True, capture_output=True)
        subprocess.run(["openssl", "rsa", "-in", str(private), "-pubout", "-out", str(public)], check=True, capture_output=True)
        checksum.write_text("0" * 64 + "  release.tar.gz\n", encoding="ascii")
        subprocess.run(["openssl", "dgst", "-sha256", "-sign", str(private), "-out", str(signature), str(checksum)], check=True, capture_output=True)
        ReleaseManager(self.root, public)._verify_signature(checksum, signature)
        checksum.write_text("1" * 64 + "  release.tar.gz\n", encoding="ascii")
        with self.assertRaises(ReleaseError):
            ReleaseManager(self.root, public)._verify_signature(checksum, signature)


if __name__ == "__main__":
    unittest.main()
