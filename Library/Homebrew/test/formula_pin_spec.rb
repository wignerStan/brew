# typed: true
# frozen_string_literal: true

require "formula_pin"

RSpec.describe FormulaPin do
  subject(:formula_pin) { described_class.new(formula) }

  let(:name) { "double" }
  let(:formula) { instance_double(Formula, name:, rack: HOMEBREW_CELLAR/name) }

  before do
    formula.rack.mkpath

    allow(formula).to receive(:installed_prefixes) do
      formula.rack.directory? ? formula.rack.subdirs.sort : []
    end

    allow(formula).to receive(:installed_kegs) do
      formula.installed_prefixes.map { |prefix| Keg.new(prefix) }
    end
  end

  it "is not pinnable by default" do
    expect(formula_pin).not_to be_pinnable
  end

  it "is pinnable if the Keg exists" do
    (formula.rack/"0.1").mkpath
    expect(formula_pin).to be_pinnable
  end

  specify "#pin and #unpin" do
    (formula.rack/"0.1").mkpath

    formula_pin.pin
    expect(formula_pin).to be_pinned
    expect(HOMEBREW_PINNED_KEGS/name).to be_a_directory
    expect(HOMEBREW_PINNED_KEGS.children.count).to eq(1)

    formula_pin.unpin
    expect(formula_pin).not_to be_pinned
    expect(HOMEBREW_PINNED_KEGS).not_to be_a_directory
  end

  it "replaces a dangling pin with a live local keg" do
    (formula.rack/"0.1").mkpath
    HOMEBREW_PINNED_KEGS.mkpath
    (HOMEBREW_PINNED_KEGS/name).make_relative_symlink(formula.rack/"missing")

    expect(formula_pin).to be_stale
    expect(formula_pin).not_to be_pinned

    formula_pin.pin
    expect(formula_pin).to be_pinned
    expect(formula_pin.pinned_version.to_s).to eq("0.1")
    formula_pin.unpin
  end

  it "removes a dangling pin" do
    HOMEBREW_PINNED_KEGS.mkpath
    (HOMEBREW_PINNED_KEGS/name).make_relative_symlink(formula.rack/"missing")

    formula_pin.unpin
    expect((HOMEBREW_PINNED_KEGS/name).symlink?).to be(false)
  end

  it "pins the newest user-owned keg instead of a newer inherited keg" do
    local_keg = formula.rack/"0.1"
    inherited_keg = formula.rack/"0.2"
    local_keg.mkpath
    inherited_keg.mkpath
    allow(Homebrew::Overlay).to receive(:inherited_keg?) do |path|
      Pathname(path) == inherited_keg
    end

    formula_pin.pin
    expect(formula_pin.pinned_version.to_s).to eq("0.1")
    formula_pin.unpin
  end

  it "treats a live inherited pin as stale and migrates it to a local keg" do
    local_keg = formula.rack/"0.1"
    inherited_keg = formula.rack/"0.2"
    local_keg.mkpath
    inherited_keg.mkpath
    HOMEBREW_PINNED_KEGS.mkpath
    (HOMEBREW_PINNED_KEGS/name).make_relative_symlink(inherited_keg)
    allow(Homebrew::Overlay).to receive(:inherited_keg?) do |path|
      Pathname(path) == inherited_keg
    end

    expect(formula_pin).to be_stale
    expect(formula_pin).not_to be_pinned

    formula_pin.pin
    expect(formula_pin).to be_pinned
    expect(formula_pin.pinned_version.to_s).to eq("0.1")
    formula_pin.unpin
  end

  it "keeps a private pin stable while the inherited package set changes" do
    local_keg = formula.rack/"0.1"
    inherited_keg = formula.rack/"0.2"
    replacement_inherited_keg = formula.rack/"0.3"
    local_keg.mkpath
    inherited_keg.mkpath
    inherited_paths = [inherited_keg]
    allow(Homebrew::Overlay).to receive(:active?).and_return(true)
    allow(Homebrew::Overlay).to receive(:inherited_keg?) do |path|
      inherited_paths.include?(Pathname(path))
    end

    formula_pin.pin
    expect(formula_pin.pinned_version.to_s).to eq("0.1")

    replacement_inherited_keg.mkpath
    inherited_paths.replace([replacement_inherited_keg])
    expect(formula_pin).to be_pinned
    expect(formula_pin.pinned_version.to_s).to eq("0.1")
    formula_pin.unpin
  end

  it "does not pin an explicitly selected inherited keg" do
    inherited_keg = formula.rack/"0.1"
    inherited_keg.mkpath
    allow(Homebrew::Overlay).to receive(:inherited_keg?) do |path|
      Pathname(path) == inherited_keg
    end

    formula_pin.pin_at(Keg.new(inherited_keg).version)
    expect(formula_pin).not_to be_pinned
  end
end
