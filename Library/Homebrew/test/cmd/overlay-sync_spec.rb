# typed: strict
# frozen_string_literal: true

require "cmd/overlay-sync"
require "cmd/shared_examples/args_parse"

RSpec.describe Homebrew::Cmd::OverlaySync do
  it_behaves_like "parseable arguments"

  it "forces an active overlay reconciliation" do
    allow(Homebrew::Overlay).to receive(:active?).and_return(true)
    allow(Homebrew::Overlay).to receive(:sync!)

    described_class.new([]).run

    expect(Homebrew::Overlay).to have_received(:sync!).once
  end

  it "rejects use outside an active overlay" do
    allow(Homebrew::Overlay).to receive(:active?).and_return(false)
    allow(Homebrew::Overlay).to receive(:sync!)

    expect { described_class.new([]).run }
      .to output(/requires an active per-user Homebrew overlay/).to_stderr
    expect(Homebrew).to have_failed
    expect(Homebrew::Overlay).not_to have_received(:sync!)
  end
end
