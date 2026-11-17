# frozen_string_literal: true

RSpec.describe Denise::Config do
  subject(:config) { described_class.new }

  describe "#add_source" do
    it "aliases a source with the provider's default alias" do
      alias_name = config.add_source(provider: "dreamhost", token: "t1")

      expect(alias_name).to eq("dh")
      expect(config.token_for("dh")).to eq("t1")
    end

    it "makes the first source the default automatically" do
      config.add_source(provider: "dreamhost", token: "t1")
      config.add_source(provider: "cloudflare", token: "t2")

      expect(config.default_source_alias).to eq("dh")
    end

    it "auto-suffixes the default alias when it is already taken" do
      config.add_source(provider: "dreamhost", token: "t1")
      second = config.add_source(provider: "dreamhost", token: "t2")

      expect(second).to eq("dh2")
    end

    it "rejects an explicit alias that is already in use" do
      config.add_source(provider: "dreamhost", token: "t1", alias_name: "dh")

      expect do
        config.add_source(provider: "cloudflare", token: "t2", alias_name: "dh")
      end.to raise_error(Denise::AliasConflictError)
    end

    it "rejects an unknown provider" do
      expect do
        config.add_source(provider: "hostgator", token: "t1")
      end.to raise_error(Denise::UnknownProviderError)
    end

    it "honors an explicit default: true even when it is not the first source" do
      config.add_source(provider: "dreamhost", token: "t1")
      config.add_source(provider: "cloudflare", token: "t2", default: true)

      expect(config.default_source_alias).to eq("cf")
    end

    it "encrypts the token at rest" do
      config.add_source(provider: "dreamhost", token: "super-secret")

      raw = File.read(Denise::Paths.config_file)
      expect(raw).not_to include("super-secret")
      expect(raw).to include("token_encrypted")
    end
  end

  describe "OS credential store (vault)" do
    let(:vault) { FakeVault.new }
    let(:vaulted) { described_class.new(vault: vault) }
    let(:file_contents) { File.read(Denise::Paths.config_file) }

    it "stores a new source's token in the vault, not config.toml" do
      vaulted.add_source(provider: "dreamhost", token: "secret-tok", alias_name: "dh")

      expect(vault.items).to eq("dh" => "secret-tok")
      expect(file_contents).not_to include("token_encrypted")
      expect(file_contents).to include('token_store = "macos-keychain"')
      expect(described_class.new(vault: vault).token_for("dh")).to eq("secret-tok")
      expect(vaulted.token_location("dh")).to eq("the macOS Keychain")
    end

    it "overwrites the vault entry on update_token" do
      vaulted.add_source(provider: "dreamhost", token: "old", alias_name: "dh")

      vaulted.update_token("dh", "new")

      expect(vault.items["dh"]).to eq("new")
    end

    it "falls back to encrypting into config.toml, with a warning, when the vault store fails" do
      failing = described_class.new(vault: FakeVault.new(fail_store: true))

      stderr = capture_stderr { failing.add_source(provider: "dreamhost", token: "tok", alias_name: "dh") }

      expect(stderr).to include("Fake Keychain store failed; keeping the token for 'dh' encrypted in config.toml")
      expect(file_contents).to include("token_encrypted")
      expect(file_contents).not_to include("token_store")
      expect(failing.token_for("dh")).to eq("tok")
    end

    it "never drops the config.toml copy unless the vault reads back the same token" do
      config.add_source(provider: "dreamhost", token: "tok", alias_name: "dh")

      capture_stderr { described_class.new(vault: FakeVault.new(mangle: true)) }

      expect(file_contents).to include("token_encrypted")
      expect(described_class.new.token_for("dh")).to eq("tok")
    end

    describe "migration on load" do
      before { config.add_source(provider: "dreamhost", token: "tok", alias_name: "dh") }

      it "moves an existing token_encrypted into the vault and removes it from config.toml" do
        stderr = capture_stderr { described_class.new(vault: vault) }

        expect(stderr).to include("moved the token for 'dh' into the Fake Keychain")
        expect(vault.items["dh"]).to eq("tok")
        expect(file_contents).not_to include("token_encrypted")
        expect(described_class.new(vault: vault).token_for("dh")).to eq("tok")
      end

      it "leaves the token encrypted and stays quiet when the vault fails (warning only with -v)" do
        failing = FakeVault.new(fail_store: true)

        expect(capture_stderr { described_class.new(vault: failing) }).to eq("")
        expect(file_contents).to include("token_encrypted")

        Denise.verbose = true
        expect(capture_stderr { described_class.new(vault: failing) }).to include("Fake Keychain store failed")
      end

      it "doesn't crash loading a token_encrypted that can't be decrypted" do
        write_config(file_contents.sub(/token_encrypted = ".*"/, 'token_encrypted = "garbage"'))

        stderr = capture_stderr { described_class.new(vault: vault) }

        expect(stderr).to include("couldn't decrypt the token for 'dh'")
        expect(vault.items).to be_empty
      end
    end

    it "sends a hand-edited plaintext token straight to the vault, replacing what was there" do
      vaulted.add_source(provider: "dreamhost", token: "old", alias_name: "dh")
      write_config(file_contents.sub('token_store = "macos-keychain"',
                                     "token = \"hand-typed\"\ntoken_store = \"macos-keychain\""))

      described_class.new(vault: vault)

      expect(vault.items["dh"]).to eq("hand-typed")
      expect(file_contents).not_to include("hand-typed")
      expect(file_contents).not_to include("token_encrypted")
    end

    it "deletes the vault entry when the source is removed" do
      vaulted.add_source(provider: "dreamhost", token: "tok", alias_name: "dh")

      vaulted.remove_source("dh")

      expect(vault.items).to be_empty
    end

    it "still removes the source, with a warning, when its vault isn't available" do
      vaulted.add_source(provider: "dreamhost", token: "tok", alias_name: "dh")
      no_vault = described_class.new(vault: nil)

      stderr = capture_stderr { no_vault.remove_source("dh") }

      expect(stderr).to include("macOS Keychain isn't available; the token for 'dh' was left in it")
      expect(described_class.new(vault: nil).sources).not_to have_key("dh")
    end

    it "raises TokenStoreUnavailableError when the source's vault isn't usable here" do
      vaulted.add_source(provider: "dreamhost", token: "tok", alias_name: "dh")

      expect { described_class.new(vault: nil).token_for("dh") }
        .to raise_error(Denise::TokenStoreUnavailableError, /macOS Keychain/)
      expect { described_class.new(vault: FakeVault.new(name: "secret-service")).token_for("dh") }
        .to raise_error(Denise::TokenStoreUnavailableError)
    end

    it "raises MissingTokenError when the vault has no entry for the source" do
      vaulted.add_source(provider: "dreamhost", token: "tok", alias_name: "dh")
      vault.items.clear

      expect { vaulted.token_for("dh") }.to raise_error(Denise::MissingTokenError, /update-token dh/)
    end

    it "never probes for a vault when nothing needs one" do
      vaulted.add_source(provider: "dreamhost", token: "tok", alias_name: "dh")
      expect(Denise::TokenVault).not_to receive(:detect)

      described_class.new.list_zones
    end

    it "shows token_store (but never the token) in to_toml_without_secrets" do
      vaulted.add_source(provider: "dreamhost", token: "secret-tok", alias_name: "dh")

      toml = vaulted.to_toml_without_secrets

      expect(toml).to include('token_store = "macos-keychain"')
      expect(toml).not_to include("secret-tok")
    end
  end

  describe "plaintext token migration" do
    it "encrypts a hand-written token on load and rewrites it as token_encrypted" do
      write_config(<<~TOML)
        [sources.dh]
        provider = "dreamhost"
        token = "hand-typed-secret"
      TOML

      migrated = described_class.new

      expect(migrated.token_for("dh")).to eq("hand-typed-secret")

      raw = File.read(Denise::Paths.config_file)
      expect(raw).not_to include("hand-typed-secret")
      expect(raw).to include("token_encrypted")
      expect(raw).not_to match(/^\s*token\s*=/)
    end

    it "prefers a freshly hand-edited token over a stale token_encrypted (manual rotation)" do
      config.add_source(provider: "dreamhost", token: "old-secret", alias_name: "dh")
      File.write(Denise::Paths.config_file, "#{File.read(Denise::Paths.config_file)}\ntoken = \"new-secret\"\n")

      rotated = described_class.new

      expect(rotated.token_for("dh")).to eq("new-secret")
    end

    it "raises MissingTokenError when a source has neither token nor token_encrypted" do
      write_config(<<~TOML)
        [sources.dh]
        provider = "dreamhost"
      TOML

      broken = described_class.new

      expect { broken.token_for("dh") }.to raise_error(Denise::MissingTokenError, /dh/)
    end
  end

  describe "legacy zone migration" do
    it "flattens {name, records} zone tables from older denise versions into bare strings" do
      write_config(<<~TOML)
        [sources.dh]
        provider = "dreamhost"
        token_encrypted = "unused"

          [[sources.dh.zones]]
          name = "example.com"
          records = []

          [[sources.dh.zones]]
          name = "example.net"
          records = []
      TOML

      migrated = described_class.new

      expect(migrated.list_zones(provider_alias: "dh")).to contain_exactly(
        { alias: "dh", name: "example.com" }, { alias: "dh", name: "example.net" }
      )
      expect(migrated.zone?("example.com", provider_alias: "dh")).to be(true)

      raw = File.read(Denise::Paths.config_file)
      expect(raw).not_to include("records")
    end

    it "leaves already-flat zones untouched" do
      config.add_source(provider: "dreamhost", token: "t1", alias_name: "dh")
      config.add_zone("example.com", provider_alias: "dh")
      before_contents = File.read(Denise::Paths.config_file)

      described_class.new

      expect(File.read(Denise::Paths.config_file)).to eq(before_contents)
    end
  end

  describe "#update_token" do
    it "replaces the token, persisted encrypted, leaving provider and zones untouched" do
      config.add_source(provider: "dreamhost", token: "old", alias_name: "dh")
      config.add_zone("example.com", provider_alias: "dh")

      config.update_token("dh", "new-secret")

      reloaded = described_class.new
      expect(reloaded.token_for("dh")).to eq("new-secret")
      expect(reloaded.source("dh")["provider"]).to eq("dreamhost")
      expect(reloaded.zone?("example.com", provider_alias: "dh")).to be(true)
      expect(File.read(Denise::Paths.config_file)).not_to include("new-secret")
    end

    it "raises for an unknown alias" do
      expect { config.update_token("nope", "t") }.to raise_error(Denise::UnknownSourceError)
    end

    it "rejects a blank token without changing the stored one" do
      config.add_source(provider: "dreamhost", token: "old", alias_name: "dh")

      expect { config.update_token("dh", "  ") }.to raise_error(Denise::BlankTokenError)
      expect { config.update_token("dh", nil) }.to raise_error(Denise::BlankTokenError)
      expect(described_class.new.token_for("dh")).to eq("old")
    end
  end

  describe "#remove_source" do
    it "falls back the default to another source when the default is removed" do
      config.add_source(provider: "dreamhost", token: "t1")
      config.add_source(provider: "cloudflare", token: "t2")

      config.remove_source("dh")

      expect(config.default_source_alias).to eq("cf")
    end

    it "raises for an unknown alias" do
      expect { config.remove_source("nope") }.to raise_error(Denise::UnknownSourceError)
    end
  end

  describe "zones" do
    before { config.add_source(provider: "dreamhost", token: "t1", alias_name: "dh") }

    it "adds and lists zones for a source" do
      config.add_zone("example.com", provider_alias: "dh")

      expect(config.list_zones(provider_alias: "dh")).to eq([{ alias: "dh", name: "example.com" }])
    end

    it "rejects a duplicate zone under the same source" do
      config.add_zone("example.com", provider_alias: "dh")

      expect do
        config.add_zone("example.com", provider_alias: "dh")
      end.to raise_error(Denise::ZoneConflictError)
    end

    it "reports every source that owns a zone name" do
      config.add_source(provider: "cloudflare", token: "t2", alias_name: "cf")
      config.add_zone("shared.com", provider_alias: "dh")
      config.add_zone("shared.com", provider_alias: "cf")

      expect(config.sources_for_zone("shared.com")).to contain_exactly("dh", "cf")
    end

    it "removes a zone" do
      config.add_zone("example.com", provider_alias: "dh")

      config.remove_zone("example.com", provider_alias: "dh")

      expect(config.list_zones(provider_alias: "dh")).to eq([])
    end
  end

  describe "#zone?" do
    before { config.add_source(provider: "dreamhost", token: "t1", alias_name: "dh") }

    it "is true for a zone tracked under the given source" do
      config.add_zone("example.com", provider_alias: "dh")

      expect(config.zone?("example.com", provider_alias: "dh")).to be(true)
    end

    it "is false for a zone not tracked under the given source" do
      expect(config.zone?("example.com", provider_alias: "dh")).to be(false)
    end
  end

  describe "#sync_zones" do
    before { config.add_source(provider: "dreamhost", token: "t1", alias_name: "dh") }

    it "adds zones that are new" do
      result = config.sync_zones("dh", ["example.com"])

      expect(result).to eq(added: ["example.com"], removed: [])
      expect(config.list_zones(provider_alias: "dh")).to eq([{ alias: "dh", name: "example.com" }])
    end

    it "removes zones no longer present" do
      config.add_zone("gone.com", provider_alias: "dh")

      result = config.sync_zones("dh", [])

      expect(result).to eq(added: [], removed: ["gone.com"])
      expect(config.list_zones(provider_alias: "dh")).to eq([])
    end

    it "leaves zones present in both untouched" do
      config.add_zone("staying.com", provider_alias: "dh")

      result = config.sync_zones("dh", ["staying.com"])

      expect(result).to eq(added: [], removed: [])
      expect(config.list_zones(provider_alias: "dh")).to eq([{ alias: "dh", name: "staying.com" }])
    end

    it "adds and removes in the same call" do
      config.add_zone("gone.com", provider_alias: "dh")

      result = config.sync_zones("dh", ["new.com"])

      expect(result).to eq(added: ["new.com"], removed: ["gone.com"])
    end

    it "raises for an unknown provider alias" do
      expect { config.sync_zones("nope", []) }.to raise_error(Denise::UnknownSourceError)
    end
  end

  it "persists across instances" do
    config.add_source(provider: "dreamhost", token: "t1")

    reloaded = described_class.new
    expect(reloaded.default_source_alias).to eq("dh")
    expect(reloaded.token_for("dh")).to eq("t1")
  end

  describe "#ensure_file!" do
    it "creates a skeleton config.toml when none exists and returns true" do
      expect(File.exist?(Denise::Paths.config_file)).to be(false)

      created = config.ensure_file!

      expect(created).to be(true)
      expect(File.exist?(Denise::Paths.config_file)).to be(true)
      expect(File.read(Denise::Paths.config_file)).to include("DeNiSe CLI configuration")
    end

    it "does not overwrite an existing config.toml, and returns false" do
      config.add_source(provider: "dreamhost", token: "t1")
      before_contents = File.read(Denise::Paths.config_file)

      created = config.ensure_file!

      expect(created).to be(false)
      expect(File.read(Denise::Paths.config_file)).to eq(before_contents)
    end
  end

  describe "#to_toml_without_secrets" do
    it "omits token_encrypted while keeping everything else" do
      config.add_source(provider: "dreamhost", token: "super-secret", alias_name: "dh", default: true)
      config.add_zone("example.com", provider_alias: "dh")

      toml = config.to_toml_without_secrets

      expect(toml).not_to include("super-secret")
      expect(toml).not_to include("token_encrypted")
      expect(toml).to include('default_source = "dh"')
      expect(toml).to include('provider = "dreamhost"')
      expect(toml).to include('zones = [ "example.com" ]')
    end

    it "includes the effective log_max_records even when unset" do
      expect(config.to_toml_without_secrets).to include("log_max_records = 10000")
    end
  end

  describe "#log_max_records" do
    it "defaults to 10000 when not set in config.toml" do
      expect(config.log_max_records).to eq(10_000)
    end

    it "honors a hand-edited log_max_records" do
      write_config("log_max_records = 500\n\n[sources]\n")

      expect(described_class.new.log_max_records).to eq(500)
    end
  end
end
