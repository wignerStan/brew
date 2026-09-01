# typed: true
# frozen_string_literal: true

require "keg"
require "overlay"

RSpec.describe Homebrew::Overlay::ReinstallSession do
  let(:keg_path) { Pathname("/tmp/homebrew-overlay/Cellar/foo/1.0") }
  let(:keg) { instance_double(Keg, to_path: keg_path.to_s) }

  before do
    allow(Homebrew::Overlay).to receive(:active?).and_return(true)
    allow(Homebrew::Overlay).to receive(:inherited_keg?).and_return(false)
  end

  it "does not intercept native or empty reinstall targets" do
    allow(Homebrew::Overlay).to receive(:active?).and_return(false)

    expect(described_class.build(keg, link_keg: false, verbose: false)).to be_nil

    allow(Homebrew::Overlay).to receive(:active?).and_return(true)
    expect(described_class.build(nil, link_keg: false, verbose: false)).to be_nil
  end

  it "restores the inherited view after an inherited reinstall failure" do
    allow(Homebrew::Overlay).to receive(:inherited_keg?).and_return(true)
    session = T.must(described_class.build(keg, link_keg: true, verbose: true))

    expect(keg).to receive(:unlink)
    session.prepare!

    expect(Homebrew::Overlay).to receive(:sync!)
    session.rollback!
  end

  it "discards a private backup after a successful reinstall" do
    backup = instance_double(Homebrew::Overlay::ReinstallBackup)
    session = T.must(described_class.build(keg, link_keg: true, verbose: true))

    allow(Homebrew::Overlay).to receive(:mutation_active?).and_return(false, true)
    expect(Homebrew::Overlay).to receive(:begin_mutation!)
    expect(keg).to receive(:unlink)
    expect(Homebrew::Overlay::ReinstallBackup).to receive(:new).with(keg_path).and_return(backup)
    expect(backup).to receive(:start!).and_return(backup)
    session.prepare!

    expect(backup).to receive(:discard!)
    expect(Homebrew::Overlay).to receive(:sync!).with(mutation: true)
    session.commit!
  end

  it "restores an uncommitted private backup and relinks it" do
    backup = instance_double(Homebrew::Overlay::ReinstallBackup)
    session = T.must(described_class.build(keg, link_keg: true, verbose: true))

    allow(Homebrew::Overlay).to receive(:mutation_active?).and_return(false)
    allow(Homebrew::Overlay).to receive(:begin_mutation!)
    allow(keg).to receive(:unlink)
    allow(Homebrew::Overlay::ReinstallBackup).to receive(:new).with(keg_path).and_return(backup)
    allow(backup).to receive(:start!).and_return(backup)
    session.prepare!

    expect(backup).to receive(:committed_replacement?).and_return(false)
    expect(backup).to receive(:restore!)
    expect(keg).to receive(:link).with(verbose: true)
    session.rollback!
  end

  it "keeps a committed private replacement after a later native failure" do
    backup = instance_double(Homebrew::Overlay::ReinstallBackup)
    session = T.must(described_class.build(keg, link_keg: true, verbose: false))

    allow(Homebrew::Overlay).to receive(:mutation_active?).and_return(false, true)
    allow(Homebrew::Overlay).to receive(:begin_mutation!)
    allow(keg).to receive(:unlink)
    allow(Homebrew::Overlay::ReinstallBackup).to receive(:new).with(keg_path).and_return(backup)
    allow(backup).to receive(:start!).and_return(backup)
    session.prepare!

    expect(backup).to receive(:committed_replacement?).and_return(true)
    expect(backup).to receive(:discard!)
    expect(Homebrew::Overlay).to receive(:sync!).with(mutation: true)
    session.rollback!
  end

  it "finishes a mutation when private backup preparation fails" do
    backup = instance_double(Homebrew::Overlay::ReinstallBackup)
    session = T.must(described_class.build(keg, link_keg: false, verbose: false))

    allow(Homebrew::Overlay).to receive(:mutation_active?).and_return(false, true)
    expect(Homebrew::Overlay).to receive(:begin_mutation!)
    expect(keg).to receive(:unlink)
    allow(Homebrew::Overlay::ReinstallBackup).to receive(:new).with(keg_path).and_return(backup)
    expect(backup).to receive(:start!).and_raise(Homebrew::Overlay::TransactionFailure, "failed")

    expect { session.prepare! }.to raise_error(Homebrew::Overlay::TransactionFailure, "failed")
    expect(Homebrew::Overlay).to receive(:sync!).with(mutation: true)
    session.rollback!
  end
end
