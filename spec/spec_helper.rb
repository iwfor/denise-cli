# frozen_string_literal: true

require_relative "../lib/denise"
require "tmpdir"
require "stringio"

RSpec.configure do |config|
  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.around do |example|
    Dir.mktmpdir("denise-spec") do |dir|
      ENV["DENISE_CONFIG_DIR"] = dir
      # Never let a spec reach the real macOS Keychain/Secret Service: specs
      # that exercise one inject a fake (FakeVault) or a fake command runner.
      ENV["DENISE_TOKEN_STORE"] = "file"
      example.run
    end
    ENV.delete("DENISE_CONFIG_DIR")
    ENV.delete("DENISE_TOKEN_STORE")
  end

  config.after { Denise.verbose = false }
end

# Swallows Thor's say/print_table/warn output so CLI specs don't spam the
# real terminal; the specs assert on state and mock calls, not on text.
def silence_output
  original_stdout = $stdout
  original_stderr = $stderr
  $stdout = File.open(File::NULL, "w")
  $stderr = File.open(File::NULL, "w")
  yield
ensure
  $stdout = original_stdout
  $stderr = original_stderr
end

# Runs the block with $stdout replaced by a StringIO and returns what was
# written to it, for specs that assert on help/output text.
def capture_stdout
  original_stdout = $stdout
  $stdout = StringIO.new
  yield
  $stdout.string
ensure
  $stdout = original_stdout
end

# Runs the block with $stderr replaced by a StringIO and returns what was
# written to it, for specs that assert on `warn`-based output (e.g. verbose
# provider logging).
def capture_stderr
  original_stderr = $stderr
  $stderr = StringIO.new
  yield
  $stderr.string
ensure
  $stderr = original_stderr
end

# Writes raw TOML directly to config.toml, bypassing Denise::Config, to
# simulate a hand-edited config file.
def write_config(toml)
  FileUtils.mkdir_p(File.dirname(Denise::Paths.config_file))
  File.write(Denise::Paths.config_file, toml)
end

# Every provider client must turn Faraday network failures into
# ProviderError (so the CLI prints `denise: ...` instead of a backtrace),
# with every secret scrubbed from the message - simulated here by an
# adapter error that echoes them back, e.g. from a URL carrying the key.
RSpec.shared_examples "a provider that wraps network errors" do |token, secrets|
  it "raises ProviderError with secrets redacted on a network failure" do
    failing = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get(/.*/) { raise Faraday::ConnectionFailed, "connection refused (#{secrets.join(' ')})" }
    end
    conn = Faraday.new(url: described_class::API_URL) { |f| f.adapter :test, failing }

    expect { described_class.new(token: token, connection: conn).list_zones }
      .to raise_error(Denise::ProviderError) { |e|
        expect(e.message).to include("failed: connection refused")
        secrets.each { |secret| expect(e.message).not_to include(secret) }
      }
  end
end

# In-memory stand-in for a Denise::TokenVault backend, injected via
# Config.new(vault:) so specs never touch a real keychain. `fail_store`
# makes every store raise; `mangle` makes reads return a different token
# than was stored (to exercise read-back verification).
class FakeVault
  attr_reader :items, :name

  def initialize(name: "macos-keychain", fail_store: false, mangle: false)
    @name = name
    @fail_store = fail_store
    @mangle = mangle
    @items = {}
  end

  def label = "Fake Keychain"

  def store(account, secret)
    raise Denise::VaultError, "Fake Keychain store failed" if @fail_store

    @items[account] = secret
  end

  def fetch(account)
    @items[account]&.then { |s| @mangle ? "#{s}-mangled" : s }
  end

  def delete(account)
    @items.delete(account)
  end
end
