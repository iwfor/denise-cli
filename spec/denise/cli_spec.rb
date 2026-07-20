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
