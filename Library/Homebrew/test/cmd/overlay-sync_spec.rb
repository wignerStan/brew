# typed: strict
# frozen_string_literal: true

require "cmd/overlay-sync"
require "formula"
require "missing"
require "cmd/shared_examples/args_parse"

RSpec.describe Homebrew::Cmd::OverlaySync do
  it_behaves_like "parseable arguments"

  it "forces an active overlay reconciliation" do
    allow(Homebrew::Overlay).to receive(:active?).and_return(true)
    expect(Homebrew::Overlay).to receive(:sync!).once

    described_class.new([]).run
  end

  it "repairs only missing dependencies of local formulae" do
    local_formula = instance_double(Formula, name: "local")
    inherited_formula = instance_double(Formula, name: "inherited")
    allow(Homebrew::Overlay).to receive(:active?).and_return(true)
    allow(Formula).to receive(:installed).and_return([local_formula, inherited_formula])
    allow(Homebrew::Overlay).to receive(:local_realizations?).with("local").and_return(true)
    allow(Homebrew::Overlay).to receive(:local_realizations?).with("inherited").and_return(false)
    allow(Homebrew::Missing).to receive(:deps).with([local_formula]).and_return({ "local" => ["dependency"] })
    command = described_class.new(["--repair"])
    expect(command).to receive(:system).with(HOMEBREW_BREW_FILE.to_s, "install", "--formula",
                                             "dependency").ordered.and_return(true)
    expect(command).to receive(:system).with(HOMEBREW_BREW_FILE.to_s, "missing", "local").ordered.and_return(true)
    expect(command).to receive(:system).with(HOMEBREW_BREW_FILE.to_s, "linkage", "--test",
                                             "local").ordered.and_return(true)
    expect(Homebrew::Overlay).to receive(:sync!).twice
    command.run
  end

  it "rebuilds only local formulae with broken linkage" do
    local_formula = instance_double(Formula, name: "local")
    allow(Homebrew::Overlay).to receive(:active?).and_return(true)
    allow(Formula).to receive(:installed).and_return([local_formula])
    allow(Homebrew::Overlay).to receive(:local_realizations?).with("local").and_return(true)
    allow(Homebrew::Missing).to receive(:deps).with([local_formula]).and_return({})
    command = described_class.new(["--repair"])
    expect(command).to receive(:system).with(HOMEBREW_BREW_FILE.to_s, "missing", "local").ordered.and_return(true)
    expect(command).to receive(:system).with(HOMEBREW_BREW_FILE.to_s, "linkage", "--test",
                                             "local").ordered.and_return(false)
    expect(command).to receive(:system).with(HOMEBREW_BREW_FILE.to_s, "reinstall", "--formula",
                                             "local").ordered.and_return(true)
    expect(command).to receive(:system).with(HOMEBREW_BREW_FILE.to_s, "linkage", "--test",
                                             "local").ordered.and_return(true)
    expect(Homebrew::Overlay).to receive(:sync!).twice
    command.run
  end

  it "rejects use outside an active overlay", :integration_test do
    allow(Homebrew::Overlay).to receive(:active?).and_return(false)
    expect(Homebrew::Overlay).not_to receive(:sync!)

    expect { described_class.new([]).run }
      .to output(/requires an active per-user Homebrew overlay/).to_stderr
    expect(Homebrew).to have_failed
  end
end
