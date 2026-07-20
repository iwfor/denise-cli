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

  describe "#sync_zones" do
    before { config.add_source(provider: "dreamhost", token: "t1", alias_name: "dh") }

    it "adds zones that are new" do
      result = config.sync_zones("dh", ["example.com"])

      expect(result).to eq(added: ["example.com"], removed: [])
      expect(config.list_zones(provider_alias: "dh")).to eq([{ alias: "dh", name: "example.com" }])
    end

    it "removes zones no longer present, dropping their records" do
      config.add_zone("gone.com", provider_alias: "dh")
      config.add_record("gone.com", provider_alias: "dh", name: "www", type: "A", value: "1.2.3.4")

      result = config.sync_zones("dh", [])

      expect(result).to eq(added: [], removed: ["gone.com"])
      expect(config.list_zones(provider_alias: "dh")).to eq([])
    end

    it "leaves zones present in both untouched, preserving their records" do
      config.add_zone("staying.com", provider_alias: "dh")
      config.add_record("staying.com", provider_alias: "dh", name: "www", type: "A", value: "1.2.3.4")

      result = config.sync_zones("dh", ["staying.com"])

      expect(result).to eq(added: [], removed: [])
      records = config.list_records("staying.com", provider_alias: "dh")
      expect(records).to eq([{ "name" => "www", "type" => "A", "value" => "1.2.3.4" }])
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

  describe "records" do
    before do
      config.add_source(provider: "dreamhost", token: "t1", alias_name: "dh")
      config.add_zone("example.com", provider_alias: "dh")
    end

    it "adds and lists records for a zone" do
      config.add_record("example.com", provider_alias: "dh", name: "www", type: "A", value: "1.2.3.4", ttl: 300)

      records = config.list_records("example.com", provider_alias: "dh")
      expect(records).to eq([{ "name" => "www", "type" => "A", "value" => "1.2.3.4", "ttl" => 300 }])
    end

    it "removes a matching record" do
      config.add_record("example.com", provider_alias: "dh", name: "www", type: "A", value: "1.2.3.4")

      config.remove_record("example.com", provider_alias: "dh", name: "www", type: "A")

      expect(config.list_records("example.com", provider_alias: "dh")).to eq([])
    end

    it "raises for an unknown record" do
      expect do
        config.remove_record("example.com", provider_alias: "dh", name: "missing", type: "A")
      end.to raise_error(Denise::UnknownRecordError)
    end
  end

  describe "#search" do
    before do
      config.add_source(provider: "dreamhost", token: "t1", alias_name: "dh")
      config.add_zone("example.com", provider_alias: "dh")
      config.add_zone("staging-example.net", provider_alias: "dh")
      config.add_record("example.com", provider_alias: "dh", name: "www", type: "A", value: "1.2.3.4")
      config.add_record("example.com", provider_alias: "dh", name: "mail", type: "CNAME", value: "www.example.com")
    end

    it "matches a zone name" do
      hits = config.search("staging", provider_alias: "dh")

      expect(hits).to eq([{ zone: "staging-example.net", match: "zone" }])
    end

    it "matches a record name" do
      hits = config.search("mail", provider_alias: "dh")

      expect(hits).to eq([{ zone: "example.com", match: "name", name: "mail", type: "CNAME",
                            value: "www.example.com", ttl: nil }])
    end

    it "matches a record value" do
      hits = config.search("1.2.3.4", provider_alias: "dh")

      expect(hits).to eq([{ zone: "example.com", match: "value", name: "www", type: "A", value: "1.2.3.4",
                            ttl: nil }])
    end

    it "reports both fields matched when the query hits a record's name and value" do
      config.add_record("example.com", provider_alias: "dh", name: "www", type: "TXT", value: "see www for info")

      hits = config.search("www", provider_alias: "dh")

      expect(hits).to contain_exactly(
        { zone: "example.com", match: "name", name: "www", type: "A", value: "1.2.3.4", ttl: nil },
        { zone: "example.com", match: "value", name: "mail", type: "CNAME", value: "www.example.com", ttl: nil },
        { zone: "example.com", match: "name,value", name: "www", type: "TXT", value: "see www for info", ttl: nil }
      )
    end

    it "is case-insensitive" do
      hits = config.search("MAIL", provider_alias: "dh")

      expect(hits.size).to eq(1)
    end

    it "restricts matching to the given categories" do
      hits = config.search("www", provider_alias: "dh", categories: %w[values])

      expect(hits).to eq(
        [{ zone: "example.com", match: "value", name: "mail", type: "CNAME", value: "www.example.com", ttl: nil }]
      )
    end

    it "raises for an unknown provider alias" do
      expect { config.search("www", provider_alias: "nope") }.to raise_error(Denise::UnknownSourceError)
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
      config.add_record("example.com", provider_alias: "dh", name: "www", type: "A", value: "1.2.3.4")

      toml = config.to_toml_without_secrets

      expect(toml).not_to include("super-secret")
      expect(toml).not_to include("token_encrypted")
      expect(toml).to include('default_source = "dh"')
      expect(toml).to include('provider = "dreamhost"')
      expect(toml).to include('name = "example.com"')
      expect(toml).to include('value = "1.2.3.4"')
    end
  end
end
