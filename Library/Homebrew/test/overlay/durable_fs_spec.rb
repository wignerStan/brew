# typed: true
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

    described_class.durable_atomic_write!(path, "ready\n", mode: 0600)

    expect(path.binread).to eq("ready\n")
    expect(path.stat.mode & 0777).to eq(0600)

    described_class.durable_unlink!(path)

    expect(path).not_to exist
  end
end
