# frozen_string_literal: true

RSpec.describe Denise::CLI do
  before do
    config = Denise::Config.new
    config.add_source(provider: "dreamhost", token: "t1", alias_name: "dh", default: true)
    config.add_zone("example.com", provider_alias: "dh")
  end

  describe "add-entry" do
    it "creates the record through the provider, then persists it locally" do
      client = instance_double(Denise::Providers::Dreamhost)
      allow(Denise::Providers).to receive(:client_for).with("dreamhost", token: "t1").and_return(client)
      expect(client).to receive(:create_record)
        .with(zone: "example.com", name: "www", type: "A", value: "1.2.3.4", ttl: nil)

      silence_output { described_class.start(%w[add-entry www --type A --value 1.2.3.4 -z example.com]) }

      entries = Denise::Config.new.list_entries("example.com", provider_alias: "dh")
      expect(entries).to eq([{ "name" => "www", "type" => "A", "value" => "1.2.3.4" }])
    end

    it "does not persist the entry locally when the provider call fails" do
      client = instance_double(Denise::Providers::Dreamhost)
      allow(Denise::Providers).to receive(:client_for).and_return(client)
      allow(client).to receive(:create_record).and_raise(Denise::ProviderError, "boom")

      expect do
        silence_output { described_class.start(%w[add-entry www --type A --value 1.2.3.4 -z example.com]) }
      end.to raise_error(SystemExit)

      entries = Denise::Config.new.list_entries("example.com", provider_alias: "dh")
      expect(entries).to eq([])
    end
  end

  describe "remove-entry" do
    before do
      Denise::Config.new.add_entry("example.com", provider_alias: "dh", name: "www", type: "A", value: "1.2.3.4")
    end

    it "deletes the record through the provider, then removes it locally" do
      client = instance_double(Denise::Providers::Dreamhost)
      allow(Denise::Providers).to receive(:client_for).with("dreamhost", token: "t1").and_return(client)
      expect(client).to receive(:delete_record).with(zone: "example.com", name: "www", type: "A")

      silence_output { described_class.start(%w[remove-entry www --type A -z example.com]) }

      entries = Denise::Config.new.list_entries("example.com", provider_alias: "dh")
      expect(entries).to eq([])
    end

    it "keeps the local entry when the provider call fails" do
      client = instance_double(Denise::Providers::Dreamhost)
      allow(Denise::Providers).to receive(:client_for).and_return(client)
      allow(client).to receive(:delete_record).and_raise(Denise::ProviderError, "boom")

      expect do
        silence_output { described_class.start(%w[remove-entry www --type A -z example.com]) }
      end.to raise_error(SystemExit)

      entries = Denise::Config.new.list_entries("example.com", provider_alias: "dh")
      expect(entries).to eq([{ "name" => "www", "type" => "A", "value" => "1.2.3.4" }])
    end
  end

  describe "add-provider" do
    it "imports zones from the live API after creating the source" do
      client = instance_double(Denise::Providers::Cloudflare)
      allow(Denise::Providers).to receive(:client_for).with("cloudflare", token: "cftoken").and_return(client)
      allow(client).to receive(:list_zones).and_return(%w[example.net example.org])

      silence_output { described_class.start(%w[add-provider cloudflare --token cftoken --alias cf]) }

      zones = Denise::Config.new.list_zones(provider_alias: "cf").map { |z| z[:name] }
      expect(zones).to contain_exactly("example.net", "example.org")
    end

    it "still adds the source even when zone import fails" do
      client = instance_double(Denise::Providers::Cloudflare)
      allow(Denise::Providers).to receive(:client_for).and_return(client)
      allow(client).to receive(:list_zones).and_raise(Denise::ProviderError, "boom")

      silence_output { described_class.start(%w[add-provider cloudflare --token cftoken --alias cf]) }

      expect(Denise::Config.new.sources).to have_key("cf")
    end
  end

  describe "refresh-zones" do
    it "syncs zones for -p ALIAS only" do
      client = instance_double(Denise::Providers::Dreamhost)
      allow(Denise::Providers).to receive(:client_for).with("dreamhost", token: "t1").and_return(client)
      allow(client).to receive(:list_zones).and_return(%w[example.com example.net])

      silence_output { described_class.start(%w[refresh-zones -p dh]) }

      zones = Denise::Config.new.list_zones(provider_alias: "dh").map { |z| z[:name] }
      expect(zones).to contain_exactly("example.com", "example.net")
    end

    it "syncs every source when -p is omitted" do
      Denise::Config.new.add_source(provider: "cloudflare", token: "cftok", alias_name: "cf")

      dh_client = instance_double(Denise::Providers::Dreamhost)
      cf_client = instance_double(Denise::Providers::Cloudflare)
      allow(Denise::Providers).to receive(:client_for).with("dreamhost", token: "t1").and_return(dh_client)
      allow(Denise::Providers).to receive(:client_for).with("cloudflare", token: "cftok").and_return(cf_client)
      allow(dh_client).to receive(:list_zones).and_return([])
      allow(cf_client).to receive(:list_zones).and_return(["zone-from-cf.com"])

      silence_output { described_class.start(["refresh-zones"]) }

      expect(Denise::Config.new.list_zones(provider_alias: "dh")).to eq([])
      cf_zones = Denise::Config.new.list_zones(provider_alias: "cf").map { |z| z[:name] }
      expect(cf_zones).to eq(["zone-from-cf.com"])
    end

    it "exits with an error for an unknown -p alias" do
      expect do
        silence_output { described_class.start(%w[refresh-zones -p nope]) }
      end.to raise_error(SystemExit)
    end

    it "continues past a per-source failure and still syncs the others" do
      Denise::Config.new.add_source(provider: "cloudflare", token: "cftok", alias_name: "cf")

      dh_client = instance_double(Denise::Providers::Dreamhost)
      cf_client = instance_double(Denise::Providers::Cloudflare)
      allow(Denise::Providers).to receive(:client_for).with("dreamhost", token: "t1").and_return(dh_client)
      allow(Denise::Providers).to receive(:client_for).with("cloudflare", token: "cftok").and_return(cf_client)
      allow(dh_client).to receive(:list_zones).and_raise(Denise::ProviderError, "boom")
      allow(cf_client).to receive(:list_zones).and_return(["zone-from-cf.com"])

      silence_output { described_class.start(["refresh-zones"]) }

      cf_zones = Denise::Config.new.list_zones(provider_alias: "cf").map { |z| z[:name] }
      expect(cf_zones).to eq(["zone-from-cf.com"])
    end
  end

  describe "-v/--verbose" do
    it "sets Denise.verbose when passed" do
      silence_output { described_class.start(%w[version -v]) }

      expect(Denise.verbose).to be(true)
    end

    it "leaves Denise.verbose false when omitted" do
      silence_output { described_class.start(["version"]) }

      expect(Denise.verbose).to be(false)
    end
  end

  describe "config" do
    it "creates a skeleton file and reports it when none exists" do
      File.delete(Denise::Paths.config_file)

      output = capture_stdout { described_class.start(["config"]) }

      expect(output).to include("No config file found")
      expect(File.exist?(Denise::Paths.config_file)).to be(true)
    end

    it "displays the existing configuration without secrets, and doesn't recreate the file" do
      output = capture_stdout { described_class.start(["config"]) }

      expect(output).not_to include("No config file found")
      expect(output).not_to include("token_encrypted")
      expect(output).to include('provider = "dreamhost"')
      expect(output).to include('name = "example.com"')
    end
  end

  describe "help" do
    it "shows a header and documents --completions when no command is given" do
      output = capture_stdout { described_class.start(["help"]) }

      expect(output).to include("DeNiSe CLI")
      expect(output).to include("--completions")
    end

    it "shows the same header for the bare invocation (no arguments)" do
      output = capture_stdout { described_class.start([]) }

      expect(output).to include("DeNiSe CLI")
      expect(output).to include("--completions")
    end

    it "does not repeat the header or --completions for a specific command" do
      output = capture_stdout { described_class.start(%w[help version]) }

      expect(output).not_to include("DeNiSe CLI")
      expect(output).not_to include("--completions")
    end
  end
end
