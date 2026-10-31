# typed: strict
# frozen_string_literal: true

require "cmd/shared_examples/args_parse"
require "dev-cmd/linkage"

RSpec.describe Homebrew::DevCmd::Linkage do
  it_behaves_like "parseable arguments"

  it "checks installed Formulae", :integration_test do
    setup_test_formula "testball", tab_attributes: { installed_on_request: true }

    expect { brew "linkage" }
      .to be_a_success
      .and not_to_output.to_stdout
      .and not_to_output.to_stderr
    expect { brew "linkage", "testball" }
      .to be_a_success
      .and not_to_output.to_stdout
      .and not_to_output.to_stderr
  end

  it "rebuilds cached library paths in an active overlay" do
    command = described_class.new(["--test", "testball"])
    keg = instance_double(Keg, name: "testball")
    checker = instance_double(LinkageChecker, display_test_output: nil, broken_library_linkage?: false)
    allow(command.args.named).to receive(:to_default_kegs).and_return([keg])
    allow(Homebrew::Overlay).to receive(:active?).and_return(true)
    allow(CacheStoreDatabase).to receive(:use).with(:linkage).and_yield(CacheStoreDatabase.new(:linkage))
    expect(LinkageChecker).to receive(:new).with(keg, hash_including(rebuild_cache: true)).and_return(checker)
    command.run
  end

  it "accepts no_linkage dependency tag" do
    expect(formula("testball") do
      T.bind(self, T.class_of(Formula))
      url "file://#{TEST_FIXTURE_DIR}/tarballs/testball-0.1.tbz"
      sha256 TESTBALL_SHA256

      depends_on "foo" => :no_linkage
    end.deps.first).to be_no_linkage
  end
end
