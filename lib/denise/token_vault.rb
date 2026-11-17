# frozen_string_literal: true

require "open3"
require "rbconfig"

module Denise
  # Stores provider API tokens in the OS credential store instead of
  # config.toml: the macOS Keychain (via `security`) or a freedesktop Secret
  # Service keyring on Linux (GNOME Keyring/KWallet/KeePassXC, via
  # `secret-tool`). Denise::Config falls back to encrypting tokens into
  # config.toml (Denise::Crypto) whenever neither is usable.
  #
  # Every backend keeps the token out of argv (it'd be visible in `ps`):
  # `security -i` reads its command line - token hex-encoded - from stdin,
  # and `secret-tool store` reads the secret itself from stdin. Errors are
  # built from the tool's stderr only, never stdout or stdin.
  module TokenVault
    # Seconds to wait on a credential-store command before giving up - a
    # locked keyring can otherwise block forever on an unlock prompt.
    TIMEOUT = 5

    module_function

    # The credential store for this platform if it's usable right now, else
    # nil. `DENISE_TOKEN_STORE=file` forces nil (the test suite sets it, so
    # specs can never touch a real keychain).
    def detect(config_dir:, runner: Runner.new, host_os: RbConfig::CONFIG["host_os"])
      return nil if ENV["DENISE_TOKEN_STORE"] == "file"

      backend = { /darwin/ => MacKeychain, /linux/ => SecretService }.find { |os, _| host_os =~ os }&.last
      vault = backend&.new(service: service_for(config_dir), runner: runner)
      vault if vault&.available?
    end

    # Includes the config directory so two configs (e.g. one under
    # DENISE_CONFIG_DIR) that share an alias never share a stored token.
    def service_for(config_dir)
      "denise-cli:#{config_dir}"
    end

    # Human-readable name for a source's `token_store` value in config.toml.
    def label_for(name)
      [MacKeychain, SecretService].find { |b| name == b::NAME }&.then { |b| b::LABEL } || name
    end

    # Runs a credential-store command with a timeout, capturing
    # stdout/stderr. Injected into backends so specs can fake it.
    class Runner
      Result = Struct.new(:stdout, :stderr, :exitstatus, keyword_init: true) do
        def success? = exitstatus.zero?
      end

      def call(*cmd, stdin: nil, timeout: TIMEOUT)
        Open3.popen3(*cmd) do |input, out, err, thread|
          readers = [out, err].map { |io| reader(io) }
          write_stdin(input, stdin)
          timeout!(cmd, thread, readers, timeout) unless thread.join(timeout)
          Result.new(stdout: readers[0].value, stderr: readers[1].value, exitstatus: thread.value.exitstatus)
        end
      rescue Errno::ENOENT
        raise VaultError, "#{cmd.first} not found"
      end

      private

      def reader(io)
        Thread.new { io.read }.tap { |t| t.report_on_exception = false }
      end

      # A command that fails before reading stdin closes the pipe on us;
      # that's its exit status's story to tell, not an exception.
      def write_stdin(input, stdin)
        input.write(stdin) if stdin
      rescue Errno::EPIPE
        nil
      ensure
        input.close
      end

      # Reap the killed process and let the readers drain to EOF before
      # popen3 closes their pipes out from under them.
      def timeout!(cmd, thread, readers, timeout)
        Process.kill("KILL", thread.pid)
        thread.join
        readers.each { |r| r.join(1) }
        raise VaultError, "#{cmd.first} timed out after #{timeout}s"
      end
    end

    # Shared shape of every backend: available?/store/fetch/delete, keyed by
    # a source alias (the account) under a per-config-dir service name.
    class Backend
      def initialize(service:, runner:)
        @service = service
        @runner = runner
      end

      def name = self.class::NAME

      def label = self.class::LABEL

      private

      def run(*cmd, stdin: nil)
        @runner.call(*cmd, stdin: stdin)
      end

      def fail!(action, result)
        detail = result.stderr.to_s.lines.first.to_s.strip
        raise VaultError, "#{label} #{action} failed#{": #{detail}" unless detail.empty?}"
      end
    end

    class MacKeychain < Backend
      NAME = "macos-keychain"
      LABEL = "macOS Keychain"
      NOT_FOUND = 44 # errSecItemNotFound, as `security`'s exit status

      def available?
        run("security", "default-keychain").success?
      rescue VaultError
        false
      end

      # `security -i` reads commands from stdin, so the token (hex-encoded
      # via -X, which also sidesteps quoting it) never appears in argv.
      def store(account, secret)
        quoted = [@service, account].map { |s| quote(s) }
        command = "add-generic-password -U -s #{quoted[0]} -a #{quoted[1]} -X #{secret.unpack1('H*')}\n"
        result = run("security", "-i", stdin: command)
        fail!("store", result) unless result.success?
      end

      def fetch(account)
        result = run("security", "find-generic-password", "-s", @service, "-a", account, "-w")
        return result.stdout.chomp if result.success?
        return nil if result.exitstatus == NOT_FOUND

        fail!("lookup", result)
      end

      def delete(account)
        result = run("security", "delete-generic-password", "-s", @service, "-a", account)
        fail!("delete", result) unless result.success? || result.exitstatus == NOT_FOUND
      end

      private

      # `security -i` splits its command line on whitespace, honoring double
      # quotes; refuse anything that could break out of them.
      def quote(value)
        raise VaultError, "#{LABEL} can't store names with quotes, backslashes, or newlines" if value.match?(/["\\\n]/)

        %("#{value}")
      end
    end

    class SecretService < Backend
      NAME = "secret-service"
      LABEL = "Secret Service keyring"

      # secret-tool exits 1 both for "no such item" (silently) and for "no
      # D-Bus session/keyring" (with an error on stderr), so a lookup of an
      # item that never exists is the only reliable availability probe.
      def available?
        result = lookup("denise-cli-availability-probe")
        result.success? || not_found?(result)
      rescue VaultError
        false
      end

      def store(account, secret)
        result = run("secret-tool", "store", "--label", "#{@service} #{account}", *attributes(account), stdin: secret)
        fail!("store", result) unless result.success?
      end

      def fetch(account)
        result = lookup(account)
        return result.stdout.chomp if result.success?
        return nil if not_found?(result)

        fail!("lookup", result)
      end

      def delete(account)
        result = run("secret-tool", "clear", *attributes(account))
        fail!("delete", result) unless result.success? || not_found?(result)
      end

      private

      def lookup(account)
        run("secret-tool", "lookup", *attributes(account))
      end

      def attributes(account)
        ["service", @service, "account", account]
      end

      def not_found?(result)
        result.exitstatus == 1 && result.stderr.strip.empty?
      end
    end
  end
end
