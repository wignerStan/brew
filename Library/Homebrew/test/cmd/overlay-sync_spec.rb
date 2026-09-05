# typed: strict
# frozen_string_literal: true

require "cmd/overlay-sync"
require "cmd/shared_examples/args_parse"

RSpec.describe Homebrew::Cmd::OverlaySync do
  it_behaves_like "parseable arguments"

  it "forces an active overlay reconciliation" do
    allow(Homebrew::Overlay).to receive(:active?).and_return(true)
    expect(Homebrew::Overlay).to receive(:sync!).once

    described_class.new([]).run
  end

  it "rejects use outside an active overlay" do
    allow(Homebrew::Overlay).to receive(:active?).and_return(false)
    expect(Homebrew::Overlay).not_to receive(:sync!)

    expect { described_class.new([]).run }
      .to output(/requires an active per-user Homebrew overlay/).to_stderr
    expect(Homebrew).to have_failed
  end
end
