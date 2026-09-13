# typed: strict
# frozen_string_literal: true

require "cmd/postinstall"
require "cmd/shared_examples/args_parse"

RSpec.describe Homebrew::Cmd::Postinstall do
  it_behaves_like "parseable arguments"

  it "runs a Formula's post-install steps", :integration_test do
    setup_test_formula "testball", <<~RUBY, tab_attributes: { installed_on_request: true }
      def post_install
        (prefix/"postinstall-ran").write "yes"
      end
    RUBY

    expect { brew "postinstall", "testball", "HOMEBREW_TEST_GENERIC_OS" => "1" }
      .to output(/Postinstalling testball/).to_stdout
      .and output(/Sandbox unavailable: running post-install without sandboxing!/).to_stderr
      .and be_a_success
    expect(Formula["testball"].prefix/"postinstall-ran").to be_a_file
  end

  it "rejects inherited formulae before running post-install code" do
    cmd = described_class.new(["foo"])
    formula = instance_double(Formula, prefix: HOMEBREW_CELLAR/"foo/1.0")
    allow(cmd.args.named).to receive(:to_resolved_formulae).and_return([formula])
    allow(Homebrew::Overlay).to receive(:inherited_keg?).with(formula.prefix).and_return(true)
    allow(Homebrew::Overlay).to receive(:base_prefix).and_return(Pathname("/home/linuxbrew/.linuxbrew"))
    expect(formula).not_to receive(:install_etc_var)

    expect { cmd.run }.to raise_error(Homebrew::Overlay::InheritedKegError)
  end

  it "runs post-install steps through `FormulaInstaller`" do
    cmd = described_class.new(["foo"])
    formula = instance_double(Formula, prefix: HOMEBREW_CELLAR/"foo/1.0", install_etc_var: nil,
                                       post_install_steps_defined?: true, post_install_defined?: false, to_s: "foo")
    installer = instance_double(FormulaInstaller)

    allow(cmd.args.named).to receive(:to_resolved_formulae).and_return([formula])
    allow(Homebrew::Overlay).to receive(:inherited_keg?).with(formula.prefix).and_return(false)
    expect(formula).not_to receive(:run_post_install_steps)
    expect(Homebrew::Overlay).to receive(:begin_mutation!).ordered
    expect(formula).to receive(:install_etc_var).ordered
    expect(FormulaInstaller).to receive(:new)
      .with(formula, debug: false, quiet: false, verbose: false)
      .ordered
      .and_return(installer)
    expect(installer).to receive(:post_install).ordered
    expect(Homebrew::Overlay).to receive(:bump_generation!).ordered

    cmd.run
  end
end
