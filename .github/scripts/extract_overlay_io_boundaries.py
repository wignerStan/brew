#!/usr/bin/env python3
from __future__ import annotations

import subprocess
from pathlib import Path


ROOT = Path(".")
CORE = ROOT / "Library/Homebrew/overlay/core.rb"
LOADER = ROOT / "Library/Homebrew/overlay.rb"
ARCHITECTURE = ROOT / "Library/Homebrew/test/support/overlay_architecture_test.sh"
README = ROOT / "Library/Homebrew/overlay/README.md"
CORE_SPEC = ROOT / "Library/Homebrew/test/overlay/core_spec.rb"


def replace_once(source: str, old: str, new: str, label: str) -> str:
    count = source.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one match, found {count}")
    return source.replace(old, new, 1)


def extract(source: str, start: str, end: str, label: str) -> tuple[str, str]:
    start_count = source.count(start)
    end_count = source.count(end)
    if start_count != 1 or end_count != 1:
        raise SystemExit(
            f"{label}: expected one start and end anchor, found {start_count} and {end_count}",
        )
    start_index = source.index(start)
    end_index = source.index(end, start_index)
    return source[:start_index] + source[end_index:], source[start_index:end_index]


def write_overlay_file(path: Path, description: str, body: str, requires: tuple[str, ...] = ()) -> None:
    require_lines = "".join(f'require "{require}"\n' for require in requires)
    separator = "\n" if require_lines else ""
    path.write_text(
        "# typed: strict\n"
        "# frozen_string_literal: true\n\n"
        f"{require_lines}{separator}"
        "module Homebrew\n"
        "  module Overlay\n"
        f"    # {description}\n"
        f"{body}"
        "  end\n"
        "end\n",
        encoding="utf-8",
    )


def git(*args: str) -> None:
    subprocess.run(["git", *args], check=True)


core = CORE.read_text(encoding="utf-8")
owned_start = (
    "    sig { params(path: Pathname, flags: Integer, mode: T.nilable(Integer)).returns(File) }\n"
    "    def self.open_retained_file"
)
owned_end = (
    "    sig { params(path: Pathname).returns(Pathname) }\n"
    "    def self.canonical_path"
)
core, owned_body = extract(core, owned_start, owned_end, "descriptor-bound I/O extraction")
CORE.write_text(core, encoding="utf-8")

write_overlay_file(
    ROOT / "Library/Homebrew/overlay/owned_io.rb",
    "Descriptor-bound opens and stable reads for security-sensitive overlay metadata.",
    owned_body,
)

loader = LOADER.read_text(encoding="utf-8")
loader = replace_once(
    loader,
    'require "overlay/core"\n',
    'require "overlay/core"\nrequire "overlay/owned_io"\n',
    "owned I/O loader registration",
)
LOADER.write_text(loader, encoding="utf-8")

(ROOT / "Library/Homebrew/test/overlay/owned_io_spec.rb").write_text(
    '''# typed: true
# frozen_string_literal: true

require "fileutils"
require "overlay"

RSpec.describe Homebrew::Overlay do
  let(:root) { mktmpdir }

  it "returns a close-on-exec descriptor owned by the caller" do
    path = root/"owner.lock"
    path.binwrite("lock")
    path.chmod 0600
    descriptor = T.let(nil, T.nilable(File))

    descriptor = described_class.open_retained_file(path, File::RDONLY | File::NOFOLLOW)

    expect(descriptor.close_on_exec?).to be(true)
    expect(descriptor.read).to eq("lock")
  ensure
    descriptor&.close unless descriptor&.closed?
  end

  it "reads stable private metadata through the retained descriptor" do
    path = root/"state"
    path.binwrite("ready\\n")
    path.chmod 0600

    contents = described_class.read_owned_file(
      path,
      description: "overlay test state",
      max_bytes:   64,
    )

    expect(contents).to eq("ready\\n")
  end

  it "returns nil when optional metadata does not exist" do
    contents = described_class.read_owned_file(
      root/"missing",
      description: "overlay test state",
      max_bytes:   64,
    )

    expect(contents).to be_nil
  end

  it "rejects metadata with another hard link" do
    path = root/"state"
    peer = root/"state-peer"
    path.binwrite("ready\\n")
    path.chmod 0600
    FileUtils.ln(path, peer)

    expect do
      described_class.read_owned_file(
        path,
        description: "overlay test state",
        max_bytes:   64,
      )
    end.to raise_error(Homebrew::Overlay::TransactionFailure, /unsafe overlay test state/)
  end
end
''',
    encoding="utf-8",
)

git(
    "add",
    "--",
    str(CORE),
    str(LOADER),
    "Library/Homebrew/overlay/owned_io.rb",
    "Library/Homebrew/test/overlay/owned_io_spec.rb",
)
git("diff", "--cached", "--check")
git("commit", "-m", "Extract descriptor-bound overlay I/O")

core = CORE.read_text(encoding="utf-8")
durable_start = (
    "    # Create a private internal directory without following any symlinked\n"
    "    # component below the native prefix."
)
durable_end = (
    "    sig { params(path: T.any(Pathname, String)).returns(T::Boolean) }\n"
    "    def self.inherited_path?"
)
core, durable_body = extract(core, durable_start, durable_end, "durable filesystem extraction")
CORE.write_text(core, encoding="utf-8")

write_overlay_file(
    ROOT / "Library/Homebrew/overlay/durable_fs.rb",
    "Crash-consistent creation, publication, synchronization, and cleanup primitives.",
    durable_body,
    requires=("fileutils", "securerandom"),
)

loader = LOADER.read_text(encoding="utf-8")
loader = replace_once(
    loader,
    'require "overlay/owned_io"\n',
    'require "overlay/owned_io"\nrequire "overlay/durable_fs"\n',
    "durable filesystem loader registration",
)
LOADER.write_text(loader, encoding="utf-8")

core_spec = CORE_SPEC.read_text(encoding="utf-8")
directory_example = '''  it "fsyncs each parent after publishing a new owned directory entry" do
    target = prefix/"durability/first/second"
    fsynced_parents = T.let([], T::Array[Pathname])
    allow(described_class).to receive(:fsync_directory!).and_wrap_original do |original, path, **options|
      fsynced_parents << path
      original.call(path, **options)
    end

    described_class.ensure_owned_directory!(target)

    expect(fsynced_parents).to eq([prefix, prefix/"durability", prefix/"durability/first"])
    expect(target).to be_a_directory
  end

'''
core_spec = replace_once(
    core_spec,
    directory_example,
    "",
    "move durable directory example out of core spec",
)
CORE_SPEC.write_text(core_spec, encoding="utf-8")

(ROOT / "Library/Homebrew/test/overlay/durable_fs_spec.rb").write_text(
    '''# typed: true
# frozen_string_literal: true

require "overlay"

RSpec.describe Homebrew::Overlay do
  let(:root) { mktmpdir }
  let(:prefix) { root/"home/.linuxbrew" }

  before do
    prefix.mkpath
    stub_const("HOMEBREW_PREFIX", prefix)
  end

  it "fsyncs each parent after publishing a new owned directory entry" do
    target = prefix/"durability/first/second"
    fsynced_parents = T.let([], T::Array[Pathname])
    allow(described_class).to receive(:fsync_directory!).and_wrap_original do |original, path, **options|
      fsynced_parents << path
      original.call(path, **options)
    end

    described_class.ensure_owned_directory!(target)

    expect(fsynced_parents).to eq([prefix, prefix/"durability", prefix/"durability/first"])
    expect(target).to be_a_directory
  end

  it "refuses to create through a symlinked directory component" do
    outside = root/"outside"
    outside.mkpath
    File.symlink(outside, prefix/"escape")

    expect do
      described_class.ensure_owned_directory!(prefix/"escape/child")
    end.to raise_error(Homebrew::Overlay::TransactionFailure, /unsafe overlay directory component/)
    expect(outside.children).to be_empty
  end

  it "durably publishes and removes a private state file" do
    path = prefix/"state"

    described_class.durable_atomic_write!(path, "ready\\n", mode: 0600)

    expect(path.binread).to eq("ready\\n")
    expect(path.stat.mode & 0777).to eq(0600)

    described_class.durable_unlink!(path)

    expect(path).not_to exist
  end
end
''',
    encoding="utf-8",
)

architecture = ARCHITECTURE.read_text(encoding="utf-8")
architecture = replace_once(
    architecture,
    '''        grep -Fx 'require "overlay/core"' "${ruby_loader}" >/dev/null || {
          echo "Error: public Ruby overlay loader no longer loads overlay/core" >&2
          exit 1
        }
''',
    '''        grep -Fx 'require "overlay/core"' "${ruby_loader}" >/dev/null || {
          echo "Error: public Ruby overlay loader no longer loads overlay/core" >&2
          exit 1
        }
        grep -Fx 'require "overlay/owned_io"' "${ruby_loader}" >/dev/null || {
          echo "Error: public Ruby overlay loader no longer loads overlay/owned_io" >&2
          exit 1
        }
        grep -Fx 'require "overlay/durable_fs"' "${ruby_loader}" >/dev/null || {
          echo "Error: public Ruby overlay loader no longer loads overlay/durable_fs" >&2
          exit 1
        }
''',
    "architecture loader checks",
)
boundary = '''        extracted_methods=(
          open_retained_file
          read_owned_file
          ensure_owned_directory!
          fsync_directory!
          fsync_tree!
          durable_atomic_write!
          durable_unlink!
          remove_tree_durable!
        )
        for extracted_method in "${extracted_methods[@]}"
        do
          if grep -Fq "def self.${extracted_method}" "${ruby_impl}/core.rb"
          then
            echo "Error: extracted overlay method returned to core.rb: ${extracted_method}" >&2
            exit 1
          fi
        done

        for owned_method in open_retained_file read_owned_file
        do
          grep -Fq "def self.${owned_method}" "${ruby_impl}/owned_io.rb" || {
            echo "Error: overlay/owned_io.rb no longer owns ${owned_method}" >&2
            exit 1
          }
        done

        for durable_method in ensure_owned_directory! fsync_directory! fsync_tree! durable_atomic_write! durable_unlink! remove_tree_durable!
        do
          grep -Fq "def self.${durable_method}" "${ruby_impl}/durable_fs.rb" || {
            echo "Error: overlay/durable_fs.rb no longer owns ${durable_method}" >&2
            exit 1
          }
        done

'''
printf_index = architecture.rfind("        printf 'overlay architecture boundary: PASS")
if printf_index < 0:
    raise SystemExit("architecture completion anchor changed")
architecture = architecture[:printf_index] + boundary + architecture[printf_index:]
ARCHITECTURE.write_text(architecture, encoding="utf-8")

readme = README.read_text(encoding="utf-8")
readme = replace_once(
    readme,
    '''- `core.rb` is the compatibility implementation boundary for path policy,
  descriptor-bound I/O, durable filesystem operations, locking, generation,
  view state, and transaction recovery. Keep new responsibilities out of this
  file and extract the existing ones behind unchanged public methods.
''',
    '''- `core.rb` is the compatibility implementation boundary for path policy,
  locking, generation, view state, and transaction recovery. Keep new
  responsibilities out of this file and extract the existing ones behind
  unchanged public methods.
- `owned_io.rb` owns descriptor-bound retained opens and stable reads of
  security-sensitive metadata.
- `durable_fs.rb` owns crash-consistent directory creation, synchronization,
  atomic publication, unlink, and detach-then-delete cleanup.
''',
    "README extraction inventory",
)
readme = replace_once(
    readme,
    '''Prefer the next extractions in this order: `owned_io.rb`, `durable_fs.rb`,
`lock_lease.rb`, `path_policy.rb`, `formula_transaction.rb`, and
`reinstall_backup.rb`. Preserve public callers and durable state formats while
moving code.
''',
    '''Prefer the next extractions in this order: `lock_lease.rb`,
`path_policy.rb`, `formula_transaction.rb`, and `reinstall_backup.rb`.
Preserve public callers and durable state formats while moving code.
''',
    "README next extraction order",
)
README.write_text(readme, encoding="utf-8")

git(
    "add",
    "--",
    str(CORE),
    str(LOADER),
    str(CORE_SPEC),
    str(ARCHITECTURE),
    str(README),
    "Library/Homebrew/overlay/durable_fs.rb",
    "Library/Homebrew/test/overlay/durable_fs_spec.rb",
)
git("diff", "--cached", "--check")
git("commit", "-m", "Extract overlay durable filesystem primitives")
