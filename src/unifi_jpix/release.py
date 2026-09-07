"""Manual, signed release activation and automatic rollback."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile
from urllib.request import urlopen

from .core import DEFAULT_ROOT, JpixError


RELEASE_RE = re.compile(r"^v[0-9]+\.[0-9]+\.[0-9]+(?:[-.][A-Za-z0-9.-]+)?$")
DEFAULT_RELEASE_URL = "https://github.com/shuuheyhey/unifi-jpix-tunnel-repair/releases/download"
MAX_DOWNLOAD_BYTES = 64 * 1024 * 1024
MAX_ARCHIVE_MEMBERS = 256
MAX_EXTRACTED_BYTES = 128 * 1024 * 1024


class ReleaseError(JpixError):
    pass


class ReleaseManager:
    def __init__(self, root: Path = DEFAULT_ROOT, public_key: Path | None = None):
        self.root = root
        self.releases = root / "releases"
        self.public_key = public_key or root / "release-signing-public.pem"

    def upgrade(self, version: str, base_url: str = DEFAULT_RELEASE_URL) -> dict[str, str]:
        if not RELEASE_RE.fullmatch(version):
            raise ReleaseError("release version is invalid")
        if not base_url.startswith("https://"):
            raise ReleaseError("release source must use HTTPS")
        if not self.public_key.is_file():
            raise ReleaseError("release signing public key is unavailable")
        self.releases.mkdir(parents=True, exist_ok=True, mode=0o755)
        with tempfile.TemporaryDirectory(prefix=".upgrade.", dir=self.root) as temporary:
            temp = Path(temporary)
            archive = temp / f"{version}.tar.gz"
            checksum = temp / f"{version}.sha256"
            signature = temp / f"{version}.sha256.sig"
            for target in (archive, checksum, signature):
                source = f"{base_url.rstrip('/')}/{version}/{target.name}"
                self._download(source, target)
            self._verify_signature(checksum, signature)
            expected = checksum.read_text(encoding="ascii").split()[0].lower()
            if not re.fullmatch(r"[0-9a-f]{64}", expected):
                raise ReleaseError("release checksum is malformed")
            actual = hashlib.sha256(archive.read_bytes()).hexdigest()
            if actual != expected:
                raise ReleaseError("release checksum mismatch")
            destination = self.releases / version
            if destination.exists():
                raise ReleaseError("release is already installed")
            stage = temp / "stage"
            stage.mkdir()
            with tarfile.open(archive, "r:gz") as package:
                self._safe_extract(package, stage)
            entries = list(stage.iterdir())
            source_root = entries[0] if len(entries) == 1 and entries[0].is_dir() else stage
            manifest = source_root / "release-manifest.json"
            if not manifest.is_file():
                raise ReleaseError("release manifest is missing")
            self._verify_manifest(source_root, manifest, version)
            os.replace(source_root, destination)
            self._select(destination.name)
            return {"status": "selected", "release": version}

    def verify_installed(self, release: Path) -> None:
        if release.parent.resolve() != self.releases.resolve() or not RELEASE_RE.fullmatch(release.name):
            raise ReleaseError("installed release path is invalid")
        if release.is_symlink() or not release.is_dir():
            raise ReleaseError("installed release is unavailable")
        manifest = release / "release-manifest.json"
        if not manifest.is_file() or manifest.is_symlink():
            raise ReleaseError("release manifest is missing")
        self._verify_manifest(release, manifest, release.name)

    def rollback(self) -> dict[str, str]:
        previous = self._link_target("previous") or self._link_target("verified")
        current = self._link_target("current")
        if not previous or previous == current:
            raise ReleaseError("no distinct verified rollback release is available")
        target = self.root / previous
        if not target.is_dir():
            raise ReleaseError("rollback release is unavailable")
        self._atomic_link("current", previous)
        return {"status": "selected", "release": Path(previous).name}

    def mark_verified(self) -> None:
        current = self._link_target("current")
        if not current:
            raise ReleaseError("current release is unavailable")
        verified = self._link_target("verified")
        if verified and verified != current:
            self._atomic_link("previous", verified)
        self._atomic_link("verified", current)

    def _select(self, name: str) -> None:
        current = self._link_target("current")
        target = f"releases/{name}"
        if current and current != target:
            self._atomic_link("previous", current)
        self._atomic_link("current", target)

    def _verify_signature(self, checksum: Path, signature: Path) -> None:
        result = subprocess.run(
            ["openssl", "dgst", "-sha256", "-verify", str(self.public_key), "-signature", str(signature), str(checksum)],
            text=True, capture_output=True, check=False,
        )
        if result.returncode != 0:
            raise ReleaseError("release signature verification failed")

    def _download(self, source: str, target: Path) -> None:
        total = 0
        with urlopen(source, timeout=30) as response, target.open("wb") as stream:
            declared = response.headers.get("Content-Length")
            if declared:
                try:
                    declared_size = int(declared)
                except ValueError as exc:
                    raise ReleaseError("release download size is invalid") from exc
                if declared_size < 0 or declared_size > MAX_DOWNLOAD_BYTES:
                    raise ReleaseError("release download exceeds the size limit")
            while True:
                chunk = response.read(1024 * 1024)
                if not chunk:
                    break
                total += len(chunk)
                if total > MAX_DOWNLOAD_BYTES:
                    raise ReleaseError("release download exceeds the size limit")
                stream.write(chunk)

    def _verify_manifest(self, root: Path, manifest_path: Path, version: str) -> None:
        try:
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise ReleaseError("release manifest is invalid") from exc
        if manifest.get("schema") != 1 or manifest.get("version") != version:
            raise ReleaseError("release manifest identity mismatch")
        files = manifest.get("files")
        if not isinstance(files, dict) or not files:
            raise ReleaseError("release manifest files are invalid")
        for relative, expected in files.items():
            if not isinstance(relative, str) or relative.startswith("/") or ".." in Path(relative).parts:
                raise ReleaseError("release manifest path is unsafe")
            target = root / relative
            if not target.is_file() or hashlib.sha256(target.read_bytes()).hexdigest() != expected:
                raise ReleaseError("release manifest checksum mismatch")
        actual_files = {
            str(path.relative_to(root)) for path in root.rglob("*")
            if path.is_file() and path != manifest_path
        }
        if actual_files != set(files):
            raise ReleaseError("release manifest does not cover the complete release")

    def _safe_extract(self, package: tarfile.TarFile, destination: Path) -> None:
        root = destination.resolve()
        members = package.getmembers()
        if len(members) > MAX_ARCHIVE_MEMBERS or sum(member.size for member in members) > MAX_EXTRACTED_BYTES:
            raise ReleaseError("release archive exceeds extraction limits")
        for member in members:
            target = (destination / member.name).resolve()
            if root not in target.parents and target != root:
                raise ReleaseError("release archive path is unsafe")
            if member.issym() or member.islnk() or member.isdev():
                raise ReleaseError("release archive contains unsupported entries")
        for member in members:
            target = destination / member.name
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True, mode=0o755)
                continue
            if not member.isfile():
                raise ReleaseError("release archive contains unsupported entries")
            target.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
            source = package.extractfile(member)
            if source is None:
                raise ReleaseError("release archive member is unreadable")
            with source, target.open("wb") as stream:
                shutil.copyfileobj(source, stream)
            target.chmod(0o755 if member.mode & 0o111 else 0o644)

    def _link_target(self, name: str) -> str | None:
        link = self.root / name
        if not link.is_symlink():
            return None
        target = os.readlink(link)
        if not re.fullmatch(r"releases/[A-Za-z0-9][A-Za-z0-9._+-]*", target):
            raise ReleaseError("release link is unsafe")
        return target

    def _atomic_link(self, name: str, target: str) -> None:
        link = self.root / name
        temporary = self.root / f".{name}.{os.getpid()}"
        temporary.unlink(missing_ok=True)
        temporary.symlink_to(target)
        os.replace(temporary, link)
