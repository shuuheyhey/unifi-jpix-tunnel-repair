#!/bin/sh
set -eu
umask 077

SOURCE_ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
[ "$#" -eq 3 ] || { printf 'usage: %s VERSION PRIVATE_KEY OUTPUT_DIR\n' "$0" >&2; exit 2; }
VERSION=$1
PRIVATE_KEY=$2
OUTPUT_DIR=$3
printf '%s\n' "$VERSION" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$' || { printf '%s\n' 'invalid release version' >&2; exit 2; }
[ -f "$PRIVATE_KEY" ] && [ ! -L "$PRIVATE_KEY" ] || { printf '%s\n' 'private key is unavailable' >&2; exit 1; }
for command in python3 openssl tar install; do
  command -v "$command" >/dev/null 2>&1 || { printf 'missing dependency: %s\n' "$command" >&2; exit 1; }
done
mkdir -p "$OUTPUT_DIR"
ARCHIVE=$OUTPUT_DIR/$VERSION.tar.gz
CHECKSUM=$OUTPUT_DIR/$VERSION.sha256
SIGNATURE=$OUTPUT_DIR/$VERSION.sha256.sig
for target in "$ARCHIVE" "$CHECKSUM" "$SIGNATURE"; do
  [ ! -e "$target" ] || { printf '%s\n' 'release output already exists' >&2; exit 1; }
done

STAGE=$(mktemp -d)
cleanup() { [ ! -d "$STAGE" ] || rm -rf -- "$STAGE"; }
trap cleanup EXIT HUP INT TERM
RELEASE=$STAGE/$VERSION
install -d -m 0755 "$RELEASE/bin" "$RELEASE/scripts" "$RELEASE/src/unifi_jpix" "$RELEASE/systemd-v2"
install -m 0755 "$SOURCE_ROOT/bin/unifi-jpix" "$RELEASE/bin/unifi-jpix"
install -m 0755 "$SOURCE_ROOT/scripts/unifi-jpix-bootstrap.sh" "$RELEASE/scripts/unifi-jpix-bootstrap.sh"
install -m 0755 "$SOURCE_ROOT/scripts/unifi-jpix-event-monitor.sh" "$RELEASE/scripts/unifi-jpix-event-monitor.sh"
install -m 0644 "$SOURCE_ROOT"/src/unifi_jpix/*.py "$RELEASE/src/unifi_jpix/"
install -m 0644 "$SOURCE_ROOT"/systemd-v2/* "$RELEASE/systemd-v2/"

python3 - "$RELEASE" "$VERSION" <<'PY'
import hashlib
import json
from pathlib import Path
import sys
root = Path(sys.argv[1])
files = {
    str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
    for path in sorted(root.rglob("*")) if path.is_file()
}
(root / "release-manifest.json").write_text(
    json.dumps({"schema": 1, "version": sys.argv[2], "files": files}, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY
chmod 0644 "$RELEASE/release-manifest.json"
tar -czf "$ARCHIVE" -C "$STAGE" "$VERSION"
python3 - "$ARCHIVE" "$CHECKSUM" <<'PY'
import hashlib
from pathlib import Path
import sys
archive = Path(sys.argv[1])
Path(sys.argv[2]).write_text(f"{hashlib.sha256(archive.read_bytes()).hexdigest()}  {archive.name}\n", encoding="ascii")
PY
openssl dgst -sha256 -sign "$PRIVATE_KEY" -out "$SIGNATURE" "$CHECKSUM"
chmod 0644 "$ARCHIVE" "$CHECKSUM" "$SIGNATURE"
printf 'unifi_jpix_release status=ready version=%s\n' "$VERSION"
