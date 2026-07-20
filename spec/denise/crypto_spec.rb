# frozen_string_literal: true

RSpec.describe Denise::Crypto do
  it "creates the key file with 0600 permissions" do
    described_class.new

    mode = File.stat(Denise::Paths.key_file).mode & 0o777
    expect(mode).to eq(0o600)
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
