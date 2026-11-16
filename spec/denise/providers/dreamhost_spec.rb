# frozen_string_literal: true

require "json"

RSpec.describe Denise::Providers::Dreamhost do
  let(:stubs) { Faraday::Adapter::Test::Stubs.new }
  let(:connection) { Faraday.new(url: described_class::API_URL) { |f| f.adapter :test, stubs } }
  let(:provider) { described_class.new(token: "tok", connection: connection) }

  after { stubs.verify_stubbed_calls }

  describe "#create_record" do
    it "adds a record using the fully-qualified name, ignoring ttl" do
      stubs.get("/") do |env|
        expect(env.params["key"]).to eq("tok")
        expect(env.params["cmd"]).to eq("dns-add_record")
        expect(env.params["record"]).to eq("www.example.com")
        expect(env.params["type"]).to eq("A")
        expect(env.params["value"]).to eq("1.2.3.4")
        [200, {}, { result: "success", data: "record added" }.to_json]
      end

      provider.create_record(zone: "example.com", name: "www", type: "A", value: "1.2.3.4", ttl: 300)
    end

    it "uses the bare zone as the record for the apex (@)" do
      stubs.get("/") do |env|
        expect(env.params["record"]).to eq("example.com")
        [200, {}, { result: "success", data: "record added" }.to_json]
      end

      provider.create_record(zone: "example.com", name: "@", type: "A", value: "1.2.3.4")
    end

    it "raises a ProviderError with DreamHost's error message" do
      stubs.get("/") { [200, {}, { result: "error", data: "record_already_exists_not_editable" }.to_json] }

      expect do
        provider.create_record(zone: "example.com", name: "www", type: "A", value: "1.2.3.4")
      end.to raise_error(Denise::ProviderError, /record_already_exists_not_editable/)
    end
  end

  describe "#delete_record" do
    it "looks up the record's current value, then removes it by name/type/value" do
      stubs.get("/") do |env|
        case env.params["cmd"]
        when "dns-list_records"
          body = {
            result: "success",
            data: [{ "zone" => "example.com", "record" => "www.example.com", "type" => "A", "value" => "1.2.3.4" }]
          }
          [200, {}, body.to_json]
        when "dns-remove_record"
          expect(env.params["record"]).to eq("www.example.com")
          expect(env.params["value"]).to eq("1.2.3.4")
          [200, {}, { result: "success", data: "record removed" }.to_json]
        end
      end

      provider.delete_record(zone: "example.com", name: "www", type: "A")
    end

    it "raises a ProviderError when no matching record exists" do
      stubs.get("/") { [200, {}, { result: "success", data: [] }.to_json] }

      expect do
        provider.delete_record(zone: "example.com", name: "missing", type: "A")
      end.to raise_error(Denise::ProviderError, /no A record named 'missing'/)
    end
  end

  describe "#list_records" do
    it "filters the full account record list down to the requested zone" do
      stubs.get("/") do
        body = {
          result: "success",
          data: [
            { "zone" => "example.com", "record" => "www.example.com", "type" => "A", "value" => "1.2.3.4" },
            { "zone" => "example.com", "record" => "example.com", "type" => "A", "value" => "5.6.7.8" },
            { "zone" => "other.com", "record" => "www.other.com", "type" => "A", "value" => "9.9.9.9" }
          ]
        }
        [200, {}, body.to_json]
      end

      expect(provider.list_records(zone: "example.com")).to eq(
        [
          { "name" => "www", "type" => "A", "value" => "1.2.3.4", "ttl" => nil },
          { "name" => "@", "type" => "A", "value" => "5.6.7.8", "ttl" => nil }
        ]
      )
    end
  end

  describe "#list_zones" do
    it "returns the unique zones across every record on the account" do
      stubs.get("/") do
        body = {
          result: "success",
          data: [
            { "zone" => "example.com", "record" => "www.example.com", "type" => "A", "value" => "1.2.3.4" },
            { "zone" => "example.com", "record" => "example.com", "type" => "A", "value" => "5.6.7.8" },
            { "zone" => "other.com", "record" => "www.other.com", "type" => "A", "value" => "9.9.9.9" }
          ]
        }
        [200, {}, body.to_json]
      end

      expect(provider.list_zones).to eq(%w[example.com other.com])
    end
  end

  describe "verbose logging" do
    let(:secret_provider) { described_class.new(token: "super-secret-dh-key-xyz", connection: connection) }

    it "logs cmd/params and the response when Denise.verbose is true, without the API key" do
      Denise.verbose = true
      stubs.get("/") { [200, {}, { result: "success", data: [] }.to_json] }

      output = capture_stderr { secret_provider.list_zones }

      expect(output).to include("GET cmd=dns-list_records")
      expect(output).to include("HTTP 200")
      expect(output).not_to include("super-secret-dh-key-xyz")
    end

    it "logs nothing when Denise.verbose is false" do
      stubs.get("/") { [200, {}, { result: "success", data: [] }.to_json] }

      output = capture_stderr { secret_provider.list_zones }

      expect(output).to eq("")
    end
  end

  it_behaves_like "a provider that wraps network errors", "super-secret-dh-key-xyz", ["super-secret-dh-key-xyz"]
end
