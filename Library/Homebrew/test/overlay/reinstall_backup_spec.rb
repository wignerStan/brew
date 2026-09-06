# typed: true
# frozen_string_literal: true

require "overlay"

RSpec.describe Homebrew::Overlay::ReinstallBackup do
  let(:root) { mktmpdir }
  let(:prefix) { root/"user" }
  let(:cellar) { prefix/"Cellar" }
  let(:base_prefix) { root/"base" }
  let(:base_generation) { "a" * 64 }
  let(:keg_path) { cellar/"foo/2.0" }

  before do
    (keg_path/"bin").mkpath
    (keg_path/"bin/foo").write("old\n")
    (base_prefix/"Cellar").mkpath
    stub_const("HOMEBREW_PREFIX", prefix)
    stub_const("HOMEBREW_CELLAR", cellar)
    allow(Homebrew::EnvConfig).to receive_messages(
      overlay?:            true,
      overlay_active?:     true,
      overlay_base_prefix: base_prefix.to_s,
    )
    allow(Homebrew::Overlay).to receive_messages(
      mutation_active?: true,
      sync!:            nil,
    )
    Homebrew::Overlay.clear_caches!
  end

  def install_replacement
    (keg_path/"bin").mkpath
    (keg_path/"bin/foo").write("new\n")
    Homebrew::Overlay.record_base_generation!(keg_path, base_generation)
  end

  it "does not treat a package-local generation marker as commit authority" do
    backup = described_class.new(keg_path).start!
    install_replacement

    expect(backup.committed_replacement?).to be(false)
    backup.restore!
    expect((keg_path/"bin/foo").read).to eq("old\n")
  end

  it "keeps the exact journal-committed replacement after its descriptive marker is removed" do
    backup = described_class.new(keg_path).start!
    install_replacement

    Homebrew::Overlay.mark_reinstall_committed!("foo", "2.0", keg_path)
    control = cellar/".homebrew-overlay-failed"/backup.id
    expect((control/"state").read).to eq("committed\n")
    (keg_path/Homebrew::Overlay::BASE_GENERATION_MARKER).unlink

    expect(backup.committed_replacement?).to be(true)
    backup.discard!
    expect(control).not_to exist
  end

  it "refuses rollback when the journal-committed replacement identity changes" do
    backup = described_class.new(keg_path).start!
    install_replacement
    Homebrew::Overlay.mark_reinstall_committed!("foo", "2.0", keg_path)
    original = cellar/"foo/2.0-original"
    keg_path.rename(original)
    install_replacement

    expect do
      backup.committed_replacement?
    end.to raise_error(Homebrew::Overlay::TransactionFailure, /replacement changed/)
  ensure
    FileUtils.rm_rf(keg_path)
    original&.rename(keg_path) if original&.exist?
    backup&.discard!
  end
end
