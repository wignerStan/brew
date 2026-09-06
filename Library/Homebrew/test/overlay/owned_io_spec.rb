# typed: true
# frozen_string_literal: true

require "fileutils"
require "overlay"

RSpec.describe Homebrew::Overlay do
  let(:root) { mktmpdir }

  it "returns a close-on-exec descriptor owned by the caller" do
    path = root/"owner.lock"
    path.binwrite("lock")
    path.chmod 0600
    descriptor = T.let(nil, T.nilable(File))

    descriptor = described_class.open_retained_file(path, File::RDONLY | File::NOFOLLOW)

    expect(descriptor.close_on_exec?).to be(true)
    expect(descriptor.read).to eq("lock")
  ensure
    descriptor&.close unless descriptor&.closed?
  end

  it "reads stable private metadata through the retained descriptor" do
    path = root/"state"
    path.binwrite("ready\n")
    path.chmod 0600

    contents = described_class.read_owned_file(
      path,
      description: "overlay test state",
      max_bytes:   64,
    )

    expect(contents).to eq("ready\n")
  end

  it "returns nil when optional metadata does not exist" do
    contents = described_class.read_owned_file(
      root/"missing",
      description: "overlay test state",
      max_bytes:   64,
    )

    expect(contents).to be_nil
  end

  it "rejects metadata with another hard link" do
    path = root/"state"
    peer = root/"state-peer"
    path.binwrite("ready\n")
    path.chmod 0600
    FileUtils.ln(path, peer)

    expect do
      described_class.read_owned_file(
        path,
        description: "overlay test state",
        max_bytes:   64,
      )
    end.to raise_error(Homebrew::Overlay::TransactionFailure, /unsafe overlay test state/)
  end
end
