# frozen_string_literal: true

require "json"

RSpec.describe Denise::Providers::Cloudflare do
  let(:stubs) { Faraday::Adapter::Test::Stubs.new }
  let(:connection) { Faraday.new(url: described_class::API_URL) { |f| f.adapter :test, stubs } }
  let(:provider) { described_class.new(token: "tok", connection: connection) }

  after { stubs.verify_stubbed_calls }

  describe "#create_record" do
    it "looks up the zone id then posts the new record" do
      stubs.get("/client/v4/zones") do |env|
        expect(env.params["name"]).to eq("example.com")
        [200, {}, { success: true, result: [{ "id" => "zone123" }] }.to_json]
      end
      stubs.post("/client/v4/zones/zone123/dns_records") do |env|
        body = JSON.parse(env.body)
        expect(body).to eq("type" => "A", "name" => "www", "content" => "1.2.3.4", "ttl" => 300)
        [200, {}, { success: true, result: { "id" => "rec1" } }.to_json]
      end

      provider.create_record(zone: "example.com", name: "www", type: "A", value: "1.2.3.4", ttl: 300)
    end

    it "raises a ProviderError when the zone doesn't exist" do
      stubs.get("/client/v4/zones") { [200, {}, { success: true, result: [] }.to_json] }

      expect do
        provider.create_record(zone: "nope.com", name: "www", type: "A", value: "1.2.3.4")
      end.to raise_error(Denise::ProviderError, /no Cloudflare zone named 'nope.com'/)
    end

    it "raises a ProviderError with the API's message on failure" do
      stubs.get("/client/v4/zones") { [200, {}, { success: true, result: [{ "id" => "zone123" }] }.to_json] }
      stubs.post("/client/v4/zones/zone123/dns_records") do
        [400, {}, { success: false, errors: [{ "message" => "Invalid record type" }] }.to_json]
      end

      expect do
        provider.create_record(zone: "example.com", name: "www", type: "BOGUS", value: "1.2.3.4")
      end.to raise_error(Denise::ProviderError, /Invalid record type/)
    end
  end

  describe "#delete_record" do
    it "finds the record by name/type then deletes it by id" do
      stubs.get("/client/v4/zones") { [200, {}, { success: true, result: [{ "id" => "zone123" }] }.to_json] }
      stubs.get("/client/v4/zones/zone123/dns_records") do |env|
        expect(env.params["name"]).to eq("www")
        expect(env.params["type"]).to eq("A")
        [200, {}, { success: true, result: [{ "id" => "rec1", "name" => "www", "type" => "A" }] }.to_json]
      end
      stubs.delete("/client/v4/zones/zone123/dns_records/rec1") do
        [200, {}, { success: true, result: { "id" => "rec1" } }.to_json]
      end

      provider.delete_record(zone: "example.com", name: "www", type: "A")
    end

    it "raises a ProviderError when no matching record exists" do
      stubs.get("/client/v4/zones") { [200, {}, { success: true, result: [{ "id" => "zone123" }] }.to_json] }
      stubs.get("/client/v4/zones/zone123/dns_records") { [200, {}, { success: true, result: [] }.to_json] }

      expect do
        provider.delete_record(zone: "example.com", name: "missing", type: "A")
      end.to raise_error(Denise::ProviderError, /no A record named 'missing'/)
    end
  end

  describe "#list_records" do
    it "returns normalized records for the zone" do
      stubs.get("/client/v4/zones") { [200, {}, { success: true, result: [{ "id" => "zone123" }] }.to_json] }
      stubs.get("/client/v4/zones/zone123/dns_records") do
        body = { success: true, result: [{ "name" => "www", "type" => "A", "content" => "1.2.3.4", "ttl" => 300 }] }
        [200, {}, body.to_json]
      end

      expect(provider.list_records(zone: "example.com")).to eq(
        [{ "name" => "www", "type" => "A", "value" => "1.2.3.4", "ttl" => 300 }]
      )
    end
  end
end
