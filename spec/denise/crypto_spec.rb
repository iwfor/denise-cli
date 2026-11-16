# frozen_string_literal: true

RSpec.describe Denise::Crypto do
  it "creates the key file with 0600 permissions" do
    described_class.new

    mode = File.stat(Denise::Paths.key_file).mode & 0o777
    expect(mode).to eq(0o600)
  end

  it "creates the key file 0600 atomically rather than chmod-ing it after writing" do
    expect(File).to receive(:open)
      .with(Denise::Paths.key_file, File::WRONLY | File::CREAT | File::EXCL | File::BINARY, 0o600)
      .and_call_original

    described_class.new
  end

  it "keeps a key another process created first instead of overwriting it" do
    FileUtils.mkdir_p(Denise::Paths.config_dir)
    File.binwrite(Denise::Paths.key_file, "k" * described_class::KEY_BYTES)
    allow(File).to receive(:exist?).and_call_original
    allow(File).to receive(:exist?).with(Denise::Paths.key_file).and_return(false)

    described_class.new

    expect(File.binread(Denise::Paths.key_file)).to eq("k" * described_class::KEY_BYTES)
  end

  it "round-trips an encrypted value" do
    crypto = described_class.new

    encrypted = crypto.encrypt("super-secret-token")

    expect(encrypted).not_to eq("super-secret-token")
    expect(crypto.decrypt(encrypted)).to eq("super-secret-token")
  end

  it "reuses the same key across instances" do
    token = described_class.new.encrypt("abc")

    expect(described_class.new.decrypt(token)).to eq("abc")
  end
end
