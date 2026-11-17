# frozen_string_literal: true

RSpec.describe Denise::TokenVault do
  # Scripted stand-in for TokenVault::Runner: records every call and answers
  # each with the first matching [matcher, result] pair (matcher is a
  # prefix of the command array).
  let(:runner_class) do
    Class.new do
      attr_reader :calls

      def initialize(responses)
        @responses = responses
        @calls = []
      end

      def call(*cmd, stdin: nil)
        @calls << { cmd: cmd, stdin: stdin }
        response = @responses.find { |prefix, _| cmd.first(prefix.size) == prefix }&.last
        raise response if response.is_a?(Exception)

        response || result(0)
      end

      def result(exitstatus, stdout: "", stderr: "")
        Denise::TokenVault::Runner::Result.new(stdout: stdout, stderr: stderr, exitstatus: exitstatus)
      end
    end
  end

  def result(exitstatus, stdout: "", stderr: "")
    Denise::TokenVault::Runner::Result.new(stdout: stdout, stderr: stderr, exitstatus: exitstatus)
  end

  def runner(responses = {})
    runner_class.new(responses)
  end

  let(:service) { Denise::TokenVault.service_for("/cfg") }

  describe ".detect" do
    around do |example|
      ENV.delete("DENISE_TOKEN_STORE")
      example.run
    end

    it "returns the macOS Keychain on darwin when `security` works" do
      vault = described_class.detect(config_dir: "/cfg", runner: runner, host_os: "darwin25")

      expect(vault).to be_a(described_class::MacKeychain)
    end

    it "returns nil on darwin when `security` fails" do
      failing = runner(%w[security] => result(1, stderr: "no default keychain"))

      expect(described_class.detect(config_dir: "/cfg", runner: failing, host_os: "darwin25")).to be_nil
    end

    it "returns the Secret Service on linux when a probe lookup cleanly finds nothing" do
      probe = runner(%w[secret-tool lookup] => result(1))

      expect(described_class.detect(config_dir: "/cfg", runner: probe, host_os: "linux-gnu"))
        .to be_a(described_class::SecretService)
    end

    it "returns nil on linux when there's no D-Bus session/keyring (exit 1 with an error)" do
      no_dbus = runner(%w[secret-tool lookup] => result(1, stderr: "Cannot autolaunch D-Bus without X11 $DISPLAY"))

      expect(described_class.detect(config_dir: "/cfg", runner: no_dbus, host_os: "linux-gnu")).to be_nil
    end

    it "returns nil when the tool isn't installed or times out" do
      missing = runner(%w[secret-tool] => Denise::VaultError.new("secret-tool not found"))

      expect(described_class.detect(config_dir: "/cfg", runner: missing, host_os: "linux-gnu")).to be_nil
    end

    it "returns nil on platforms with no supported credential store" do
      expect(described_class.detect(config_dir: "/cfg", runner: runner, host_os: "mingw32")).to be_nil
    end

    it "returns nil without probing anything when DENISE_TOKEN_STORE=file" do
      ENV["DENISE_TOKEN_STORE"] = "file"
      probe = runner

      expect(described_class.detect(config_dir: "/cfg", runner: probe, host_os: "darwin25")).to be_nil
      expect(probe.calls).to be_empty
    end
  end

  describe ".service_for" do
    it "differs per config directory, so configs sharing an alias never share a token" do
      expect(described_class.service_for("/a")).not_to eq(described_class.service_for("/b"))
    end
  end

  describe ".label_for" do
    it "maps a token_store name to its human label, passing unknown names through" do
      expect(described_class.label_for("macos-keychain")).to eq("macOS Keychain")
      expect(described_class.label_for("secret-service")).to eq("Secret Service keyring")
      expect(described_class.label_for("mystery")).to eq("mystery")
    end
  end

  describe described_class::MacKeychain do
    let(:secret) { %(we"ird \\ tok$en) }

    it "stores via `security -i` on stdin, hex-encoding the token, so it never appears in argv" do
      fake = runner
      described_class.new(service: service, runner: fake).store("dh", secret)

      call = fake.calls.last
      expect(call[:cmd]).to eq(%w[security -i])
      expect(call[:stdin]).to eq(
        %(add-generic-password -U -s "#{service}" -a "dh" -X #{secret.unpack1('H*')}\n)
      )
      expect(call[:stdin]).not_to include(secret)
    end

    it "accepts ordinary names (including the letter n) but rejects ones that could escape the quoting" do
      vault = described_class.new(service: service, runner: runner)

      expect { vault.store("normal-name", "t") }.not_to raise_error
      ["a\"b", "a\\b", "a\nb"].each do |bad|
        expect { vault.store(bad, "t") }.to raise_error(Denise::VaultError, /quotes, backslashes, or newlines/)
      end
    end

    it "raises VaultError with the tool's error (never the token) when a store fails" do
      failing = runner(%w[security -i] => result(2, stderr: "security: Unable to store\nusage..."))

      expect { described_class.new(service: service, runner: failing).store("dh", secret) }
        .to raise_error(Denise::VaultError, "macOS Keychain store failed: security: Unable to store")
    end

    it "fetches with find-generic-password -w, returning nil when the item doesn't exist" do
      vault = described_class.new(service: service, runner: runner(
        %W[security find-generic-password -s #{service} -a dh] => result(0, stdout: "tok\n"),
        %w[security find-generic-password] => result(44)
      ))

      expect(vault.fetch("dh")).to eq("tok")
      expect(vault.fetch("nope")).to be_nil
    end

    it "raises VaultError on any other lookup failure" do
      vault = described_class.new(service: service, runner: runner(%w[security] => result(51, stderr: "locked")))

      expect { vault.fetch("dh") }.to raise_error(Denise::VaultError, /lookup failed: locked/)
    end

    it "treats deleting a missing item as success" do
      vault = described_class.new(service: service, runner: runner(%w[security] => result(44)))

      expect { vault.delete("dh") }.not_to raise_error
    end
  end

  describe described_class::SecretService do
    it "stores with the token on stdin, never in argv" do
      fake = runner
      described_class.new(service: service, runner: fake).store("dh", "s3cret")

      call = fake.calls.last
      expect(call[:cmd]).to eq(["secret-tool", "store", "--label", "#{service} dh",
                                "service", service, "account", "dh"])
      expect(call[:stdin]).to eq("s3cret")
    end

    it "fetches, returning nil when the item doesn't exist and raising on real errors" do
      vault = described_class.new(service: service, runner: runner(
        ["secret-tool", "lookup", "service", service, "account", "dh"] => result(0, stdout: "tok"),
        ["secret-tool", "lookup", "service", service, "account", "nope"] => result(1),
        %w[secret-tool lookup] => result(1, stderr: "secret-tool: No such interface")
      ))

      expect(vault.fetch("dh")).to eq("tok")
      expect(vault.fetch("nope")).to be_nil
      expect { vault.fetch("other") }.to raise_error(Denise::VaultError, /No such interface/)
    end

    it "clears by the same attributes it stores under" do
      fake = runner
      described_class.new(service: service, runner: fake).delete("dh")

      expect(fake.calls.last[:cmd]).to eq(["secret-tool", "clear", "service", service, "account", "dh"])
    end
  end

  describe described_class::Runner do
    it "passes stdin and captures stdout, stderr, and exit status" do
      result = described_class.new.call("sh", "-c", "cat; echo oops >&2; exit 3", stdin: "hello")

      expect(result.stdout).to eq("hello")
      expect(result.stderr).to eq("oops\n")
      expect(result.exitstatus).to eq(3)
      expect(result.success?).to be(false)
    end

    it "kills the command and raises VaultError on timeout" do
      expect { described_class.new.call("sleep", "5", timeout: 0.2) }
        .to raise_error(Denise::VaultError, /timed out/)
    end

    it "raises VaultError when the command isn't installed" do
      expect { described_class.new.call("denise-no-such-tool") }
        .to raise_error(Denise::VaultError, /not found/)
    end
  end
end
