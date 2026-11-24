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
    it "finds the record by full name/type then deletes it by id" do
      stubs.get("/client/v4/zones") { [200, {}, { success: true, result: [{ "id" => "zone123" }] }.to_json] }
      stubs.get("/client/v4/zones/zone123/dns_records") do |env|
        # Cloudflare's name filter only matches full names.
        expect(env.params["name"]).to eq("www.example.com")
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

    it "refuses to pick one when several records share the name and type" do
      stubs.get("/client/v4/zones") { [200, {}, { success: true, result: [{ "id" => "zone123" }] }.to_json] }
      stubs.get("/client/v4/zones/zone123/dns_records") do
        [200, {}, { success: true, result: [{ "id" => "r1", "content" => "1.1.1.1" },
                                            { "id" => "r2", "content" => "2.2.2.2" }] }.to_json]
      end

      expect do
        provider.delete_record(zone: "example.com", name: "www", type: "A")
      end.to raise_error(Denise::AmbiguousRecordError, /2 A records \(1\.1\.1\.1, 2\.2\.2\.2\)/)
    end
  end

  describe "#create_record with proxied" do
    it "sends proxied only when given" do
      stubs.get("/client/v4/zones") { [200, {}, { success: true, result: [{ "id" => "zone123" }] }.to_json] }
      stubs.post("/client/v4/zones/zone123/dns_records") do |env|
        expect(JSON.parse(env.body)).to eq("type" => "CNAME", "name" => "www", "content" => "t.example.net",
                                           "proxied" => true)
        [200, {}, { success: true, result: { "id" => "rec1" } }.to_json]
      end

      provider.create_record(zone: "example.com", name: "www", type: "CNAME", value: "t.example.net", proxied: true)
    end
  end

  describe "#update_record" do
    let(:www) { { "id" => "rec1", "name" => "www.example.com", "type" => "CNAME", "content" => "old.example.net" } }

    before do
      stubs.get("/client/v4/zones") { [200, {}, { success: true, result: [{ "id" => "zone123" }] }.to_json] }
    end

    it "patches only the content, so the record keeps proxied and ttl, and returns the new record" do
      stubs.get("/client/v4/zones/zone123/dns_records") do |env|
        expect(env.params["name"]).to eq("www.example.com")
        [200, {}, { success: true, result: [www] }.to_json]
      end
      stubs.patch("/client/v4/zones/zone123/dns_records/rec1") do |env|
        expect(JSON.parse(env.body)).to eq("content" => "new.example.net")
        [200, {}, { success: true, result: www.merge("content" => "new.example.net", "ttl" => 1,
                                                     "proxied" => true) }.to_json]
      end

      expect(provider.update_record(zone: "example.com", name: "www", type: "CNAME", value: "new.example.net"))
        .to eq("name" => "www.example.com", "type" => "CNAME", "value" => "new.example.net", "ttl" => 1,
               "proxied" => true)
    end

    it "sends ttl and proxied when given" do
      stubs.get("/client/v4/zones/zone123/dns_records") { [200, {}, { success: true, result: [www] }.to_json] }
      stubs.patch("/client/v4/zones/zone123/dns_records/rec1") do |env|
        expect(JSON.parse(env.body)).to eq("content" => "new.example.net", "ttl" => 300, "proxied" => false)
        [200, {}, { success: true, result: www }.to_json]
      end

      provider.update_record(zone: "example.com", name: "www.example.com", type: "CNAME",
                             value: "new.example.net", ttl: 300, proxied: false)
    end

    it "picks the record whose content is old_value when the name has several" do
      stubs.get("/client/v4/zones/zone123/dns_records") do
        [200, {}, { success: true, result: [{ "id" => "r1", "content" => "1.1.1.1" },
                                            { "id" => "r2", "content" => "2.2.2.2" }] }.to_json]
      end
      stubs.patch("/client/v4/zones/zone123/dns_records/r2") do
        [200, {}, { success: true, result: { "id" => "r2", "content" => "3.3.3.3" } }.to_json]
      end

      provider.update_record(zone: "example.com", name: "www", type: "A", value: "3.3.3.3", old_value: "2.2.2.2")
    end

    it "refuses when several records match and no old_value picks one" do
      stubs.get("/client/v4/zones/zone123/dns_records") do
        [200, {}, { success: true, result: [{ "id" => "r1", "content" => "1.1.1.1" },
                                            { "id" => "r2", "content" => "2.2.2.2" }] }.to_json]
      end

      expect do
        provider.update_record(zone: "example.com", name: "www", type: "A", value: "3.3.3.3")
      end.to raise_error(Denise::AmbiguousRecordError, /--old-value/)
    end
  end

  describe "#list_records" do
    it "returns normalized records for the zone, including proxied" do
      stubs.get("/client/v4/zones") { [200, {}, { success: true, result: [{ "id" => "zone123" }] }.to_json] }
      stubs.get("/client/v4/zones/zone123/dns_records") do
        body = { success: true, result: [{ "name" => "www", "type" => "A", "content" => "1.2.3.4", "ttl" => 300,
                                           "proxied" => true }] }
        [200, {}, body.to_json]
      end

      expect(provider.list_records(zone: "example.com")).to eq(
        [{ "name" => "www", "type" => "A", "value" => "1.2.3.4", "ttl" => 300, "proxied" => true }]
      )
    end

    it "follows pagination past Cloudflare's 100-record page" do
      stubs.get("/client/v4/zones") { [200, {}, { success: true, result: [{ "id" => "zone123" }] }.to_json] }
      stubs.get("/client/v4/zones/zone123/dns_records") do |env|
        expect(env.params["per_page"]).to eq("100")
        name = env.params["page"] == "1" ? "a" : "b"
        [200, {}, { success: true, result: [{ "name" => name, "type" => "A", "content" => "1.2.3.4" }],
                    result_info: { total_pages: 2 } }.to_json]
      end

      expect(provider.list_records(zone: "example.com").map { |r| r["name"] }).to eq(%w[a b])
    end
  end

  describe "#list_zones" do
    it "returns every zone name on the account, following pagination" do
      stubs.get("/client/v4/zones") do |env|
        case env.params["page"]
        when "1"
          body = {
            success: true,
            result: [{ "name" => "example.com" }],
            result_info: { page: 1, total_pages: 2 }
          }
          [200, {}, body.to_json]
        when "2"
          body = {
            success: true,
            result: [{ "name" => "example.net" }],
            result_info: { page: 2, total_pages: 2 }
          }
          [200, {}, body.to_json]
        end
      end

      expect(provider.list_zones).to eq(%w[example.com example.net])
    end
  end

  describe "verbose logging" do
    let(:secret_provider) { described_class.new(token: "super-secret-cf-token-xyz", connection: connection) }

    it "logs the request and response when Denise.verbose is true, without the token" do
      Denise.verbose = true
      stubs.get("/client/v4/zones") { [200, {}, { success: true, result: [{ "id" => "zone123" }] }.to_json] }
      stubs.get("/client/v4/zones/zone123/dns_records") do
        [200, {}, { success: true, result: [] }.to_json]
      end

      output = capture_stderr { secret_provider.list_records(zone: "example.com") }

      expect(output).to include("GET zones/zone123/dns_records")
      expect(output).to include("HTTP 200")
      expect(output).not_to include("super-secret-cf-token-xyz")
    end

    it "logs nothing when Denise.verbose is false" do
      stubs.get("/client/v4/zones") { [200, {}, { success: true, result: [{ "id" => "zone123" }] }.to_json] }
      stubs.get("/client/v4/zones/zone123/dns_records") { [200, {}, { success: true, result: [] }.to_json] }

      output = capture_stderr { secret_provider.list_records(zone: "example.com") }

      expect(output).to eq("")
    end
  end

  it_behaves_like "a provider that wraps network errors", "super-secret-cf-token-xyz", ["super-secret-cf-token-xyz"]
end
