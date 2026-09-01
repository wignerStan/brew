# typed: true
# frozen_string_literal: true

require "formula"
require "keg"
require "overlay"
require "sandbox"

RSpec.describe Homebrew::Overlay::InstallSession do
  let(:generation) { "a" * 64 }
  let(:formula) do
    instance_double(
      Formula,
      name:        "foo",
      full_name:   "foo",
      pkg_version: PkgVersion.parse("2.0"),
    )
  end
  let(:keg) { instance_double(Keg, to_path: Pathname("/tmp/Cellar/foo/2.0")) }

  before do
    allow(Homebrew::Overlay).to receive_messages(
      active?:                     false,
      local_keg_realization?:      false,
      mutation_active?:            false,
      release_base_mutation_lease: nil,
    )
    allow(Homebrew::EnvConfig).to receive(:overlay?).and_return(false)
    allow(Homebrew).to receive_messages(
      failed?:   false,
      "failed=": nil,
    )
  end

  it "uses the current formula and exposes its transaction to the build sandbox" do
    lease = instance_double(File)
    transaction_dir = Pathname("/tmp/overlay/transactions/123")
    transaction = instance_double(
      Homebrew::Overlay::FormulaTransaction,
      id:              "123",
      transaction_dir: transaction_dir,
      finished?:       false,
    )
    sandbox = instance_double(Sandbox)

    allow(Homebrew::Overlay).to receive_messages(
      active?:                     true,
      acquire_base_mutation_lease: lease,
      current_base_generation:     generation,
      mutation_active?:            true,
    )
    expect(Homebrew::Overlay).to receive(:begin_formula_transaction)
      .with(formula, base_generation: generation)
      .and_return(transaction)

    session = described_class.new
    session.start!(formula)

    expect(session.managed?).to be(true)
    expect(session.build_environment).to eq(
      "HOMEBREW_OVERLAY_INSTALL_TRANSACTION_ID" => "123",
    )
    expect(sandbox).to receive(:allow_read_if_exists).with(path: transaction_dir)
    session.apply_build_sandbox_rules(sandbox)

    expect(transaction).to receive(:rollback!)
    session.abort!
    expect(Homebrew::Overlay).to receive(:release_base_mutation_lease).with(lease)
    session.close!
  end

  it "commits a local realization through one durable session boundary" do
    lease = instance_double(File)
    allow(Homebrew::Overlay).to receive_messages(
      active?:                     true,
      acquire_base_mutation_lease: lease,
      begin_formula_transaction:   nil,
      current_base_generation:     generation,
    )
    allow(Homebrew::EnvConfig).to receive(:overlay?).and_return(true)
    expect(Homebrew::Overlay).to receive(:validate_local_install_target!).with("foo", "2.0")
    expect(Homebrew::Overlay).to receive(:begin_mutation!)

    session = described_class.new
    session.start!(formula)

    expect(Homebrew::Overlay).to receive(:verify_base_generation!).with(generation).exactly(3).times
    expect(Homebrew::Overlay).to receive(:record_base_generation!).with(keg.to_path, generation)
    expect(Homebrew::Overlay).to receive(:bump_generation!)
    session.commit!(keg)

    expect(Homebrew::Overlay).not_to receive(:discard_local_keg!)
    expect(Homebrew::Overlay).not_to receive(:sync!)
    session.abort!
    expect(Homebrew::Overlay).to receive(:release_base_mutation_lease).with(lease)
    session.close!
  end

  it "raises when Homebrew reports failure before the package boundary" do
    allow(Homebrew::Overlay).to receive_messages(
      active?:                     true,
      acquire_base_mutation_lease: instance_double(File),
      begin_formula_transaction:   nil,
      current_base_generation:     generation,
    )
    allow(Homebrew::EnvConfig).to receive(:overlay?).and_return(true)
    allow(Homebrew).to receive(:failed?).and_return(false, true)
    allow(Homebrew::Overlay).to receive_messages(
      begin_mutation!:         nil,
      verify_base_generation!: nil,
    )

    session = described_class.new
    session.start!(formula)

    expect do
      session.validate_install!
    end.to raise_error(
      Homebrew::Overlay::TransactionFailure,
      /failed before its private keg was committed/,
    )
  end

  it "discards an uncommitted new local keg and finalizes its mutation" do
    lease = instance_double(File)
    allow(Homebrew::Overlay).to receive_messages(
      active?:                     true,
      acquire_base_mutation_lease: lease,
      begin_formula_transaction:   nil,
      current_base_generation:     generation,
    )
    allow(Homebrew::Overlay).to receive(:mutation_active?).and_return(false, true)
    allow(Homebrew::EnvConfig).to receive(:overlay?).and_return(true)
    expect(Homebrew::Overlay).to receive(:begin_mutation!)

    session = described_class.new
    session.start!(formula)

    expect(Homebrew::Overlay).to receive(:discard_local_keg!).with("foo", "2.0")
    expect(Homebrew::Overlay).to receive(:sync!).with(mutation: true)
    session.abort!
    expect(Homebrew::Overlay).to receive(:release_base_mutation_lease).with(lease)
    session.close!
  end

  it "preserves a pre-existing local keg when installation aborts" do
    allow(Homebrew::Overlay).to receive_messages(
      active?:                     true,
      acquire_base_mutation_lease: instance_double(File),
      begin_formula_transaction:   nil,
      current_base_generation:     generation,
      local_keg_realization?:      true,
    )
    allow(Homebrew::EnvConfig).to receive(:overlay?).and_return(true)
    allow(Homebrew::Overlay).to receive_messages(
      begin_mutation!: nil,
      sync!:           nil,
    )

    session = described_class.new
    session.start!(formula)

    expect(Homebrew::Overlay).not_to receive(:discard_local_keg!)
    session.abort!
  end

  it "closes the failure scope and lease after rollback errors" do
    lease = instance_double(File)
    transaction = instance_double(
      Homebrew::Overlay::FormulaTransaction,
      finished?: false,
    )
    allow(Homebrew::Overlay).to receive_messages(
      active?:                     true,
      acquire_base_mutation_lease: lease,
      begin_formula_transaction:   transaction,
      current_base_generation:     generation,
      mutation_active?:            true,
    )
    allow(Homebrew).to receive(:failed?).and_return(true, false)
    expect(Homebrew).to receive(:failed=).with(false).ordered
    expect(transaction).to receive(:rollback!).ordered.and_raise(
      Homebrew::Overlay::TransactionFailure,
      "rollback failed",
    )
    expect(Homebrew).to receive(:failed=).with(true).ordered
    expect(Homebrew::Overlay).to receive(:release_base_mutation_lease).with(lease).ordered

    session = described_class.new
    session.start!(formula)

    expect do
      session.abort!
    ensure
      session.close!
    end.to raise_error(Homebrew::Overlay::TransactionFailure, "rollback failed")
  end

  it "finishes a writable administrator mutation after native install work" do
    allow(Homebrew::EnvConfig).to receive(:overlay?).and_return(true)
    expect(Homebrew::Overlay).to receive(:begin_mutation!)

    session = described_class.new
    session.start!(formula)

    expect(session.managed?).to be(false)
    expect(Homebrew::Overlay).to receive(:bump_generation!)
    session.complete_native_install!
  end
end
