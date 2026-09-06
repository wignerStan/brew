#!/bin/bash
# Ruby metadata readers must bind validation and bytes to one open descriptor.
set -euo pipefail

repo="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)}"
repo="$(cd "${repo}" && pwd -P)"
work="$(mktemp -d "${TMPDIR:-/tmp}/homebrew-overlay-ruby-reader.XXXXXX")"
trap 'rm -rf -- "${work}"' EXIT

# Reproduce the underlying race independently: path validation followed by a
# pathname read can consume a replacement inode, while an O_NOFOLLOW descriptor
# remains bound to the validated inode and exposes the path-identity mismatch.
python3 - "${work}" <<'PY'
import os
from pathlib import Path
import sys

root = Path(sys.argv[1])
path = root / "metadata"
original = root / "original"
replacement = root / "replacement"
path.write_bytes(b"trusted\n")
replacement.write_bytes(b"attacker\n")
fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
try:
    path.rename(original)
    replacement.rename(path)
    assert os.read(fd, 64) == b"trusted\n"
    descriptor = os.fstat(fd)
    pathname = os.lstat(path)
    assert (descriptor.st_dev, descriptor.st_ino) != (pathname.st_dev, pathname.st_ino)
finally:
    os.close(fd)
PY

python3 \
  - "${repo}/Library/Homebrew/overlay/core.rb" \
  "${repo}/Library/Homebrew/overlay/owned_io.rb" <<'PY'
from pathlib import Path
import sys

core = Path(sys.argv[1]).read_text(encoding="utf-8")
owned_io = Path(sys.argv[2]).read_text(encoding="utf-8")
assert "def self.read_owned_file" in owned_io
assert "def self.read_owned_file" not in core
reader_start = owned_io.index("    def self.read_owned_file")
reader = owned_io[reader_start:]
for required in (
    "File::NOFOLLOW",
    "file.stat",
    "path.lstat",
    "descriptor_stat.dev == path_stat.dev",
    "descriptor_stat.ino == path_stat.ino",
    "file.read",
):
    assert required in reader, required
assert reader.count("path.lstat") >= 2
assert reader.count("file.stat") >= 2

marker_start = core.index("      def marker_owned?")
marker_end = core.index("\n      sig { returns(T::Boolean) }", marker_start)
marker = core[marker_start:marker_end]
assert "Overlay.read_owned_file" in marker
assert ".binread" not in marker
assert ".lstat" not in marker

state_start = core.index("    def self.link_state_entries")
state_end = core.index("\n    private_class_method :link_state_entries", state_start)
state = core[state_start:state_end]
assert "read_owned_file" in state
assert ".binread" not in state
assert ".stat" not in state
PY

printf 'overlay Ruby reader integrity test: PASS\n'
