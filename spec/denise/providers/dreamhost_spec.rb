# frozen_string_literal: true

require "json"

# Request/response shapes follow DreamHost's v1 OpenAPI spec
# (https://developers.dreamhost.com/spec/external/json?version=v1).
RSpec.describe Denise::Providers::Dreamhost do
  let(:stubs) { Faraday::Adapter::Test::Stubs.new }
  let(:connection) { Faraday.new(url: described_class::API_URL) { |f| f.adapter :test, stubs } }
  let(:sleeps) { [] }
  let(:provider) do
    described_class.new(token: "tok", connection: connection, sleeper: ->(seconds) { sleeps << seconds })
  end

  def task(status, id: "928144")
    { taskId: id, status: status, createdAt: "2026-11-28T10:15:24.000Z", completedAt: nil }.to_json
  end

  def record(name, type, value, protected: false)
    { name: name, domain: name == "@" ? "example.com" : "#{name}.example.com", type: type, value: value,
      fields: {}, isProtected: protected, managedBy: protected ? "hosting" : nil }
  end

  def json_body(env)
    JSON.parse(env.body)
  end

  after { stubs.verify_stubbed_calls }

  it "authenticates with the API key as a Bearer token on the v1 base URL" do
    conn = described_class.new(token: "tok").send(:connection)

    expect(conn.headers["Authorization"]).to eq("Bearer tok")
    expect(conn.url_prefix.to_s).to eq("https://api.dreamhost.com/v1/")
  end

  describe "#create_record" do
    it "POSTs the record with its value in the type's field, with an idempotency key, ignoring ttl" do
      stubs.post("/v1/dns/example.com") do |env|
        expect(json_body(env)).to eq(
          "records" => [{ "name" => "www", "type" => "A", "fields" => { "ip" => "1.2.3.4" } }]
        )
        expect(env.request_headers["Idempotency-Key"]).to match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)
        [202, {}, task("success")]
      end

      provider.create_record(zone: "example.com", name: "www", type: "A", value: "1.2.3.4", ttl: 300)
    end

    it "uses fields.content for hostname/text types" do
      stubs.post("/v1/dns/example.com") do |env|
        expect(json_body(env)["records"].first["fields"]).to eq("content" => "target.example.net")
        [202, {}, task("success")]
      end

      provider.create_record(zone: "example.com", name: "argo.home", type: "cname", value: "target.example.net")
    end

    it "sends @ for an empty name (the zone apex)" do
      stubs.post("/v1/dns/example.com") do |env|
        expect(json_body(env)["records"].first["name"]).to eq("@")
        [202, {}, task("success")]
      end

      provider.create_record(zone: "example.com", name: "", type: "AAAA", value: "2001:db8::1")
    end

    it "polls the returned task until it succeeds, saying once on stderr that it's waiting" do
      stubs.post("/v1/dns/example.com") { [202, {}, task("scheduled")] }
      stubs.get("/v1/tasks/928144") { [200, {}, task("scheduled")] }
      stubs.get("/v1/tasks/928144") { [200, {}, task("success")] }

      output = capture_stderr do
        provider.create_record(zone: "example.com", name: "www", type: "A", value: "1.2.3.4")
      end

      expect(sleeps).to eq([described_class::TASK_POLL_INTERVAL] * 2)
      expect(output.lines.size).to eq(1)
      expect(output).to include("Waiting for DreamHost to apply the change (task 928144")
    end

    it "prints nothing while waiting when the task has already succeeded" do
      stubs.post("/v1/dns/example.com") { [202, {}, task("success")] }

      output = capture_stderr do
        provider.create_record(zone: "example.com", name: "www", type: "A", value: "1.2.3.4")
      end

      expect(output).to eq("")
      expect(sleeps).to be_empty
    end

    it "raises a ProviderError when the task fails" do
      stubs.post("/v1/dns/example.com") { [202, {}, task("failure")] }

      expect do
        provider.create_record(zone: "example.com", name: "www", type: "A", value: "1.2.3.4")
      end.to raise_error(Denise::ProviderError, /task 928144 ended with status 'failure'/)
    end

    it "raises a ProviderError when the task is still pending after the timeout" do
      stubs.post("/v1/dns/example.com") { [202, {}, task("scheduled")] }
      stubs.get("/v1/tasks/928144") { [200, {}, task("scheduled")] }

      expect do
        capture_stderr { provider.create_record(zone: "example.com", name: "www", type: "A", value: "1.2.3.4") }
      end.to raise_error(Denise::ProviderError, /accepted the change but task 928144 is still pending.*may still apply/)
      expect(sleeps.sum).to eq(described_class::TASK_TIMEOUT)
    end

    it "refuses record types it can't express as DreamHost fields, without calling the API" do
      expect do
        provider.create_record(zone: "example.com", name: "@", type: "MX", value: "10 mail.example.com")
      end.to raise_error(Denise::ProviderError, /can't create MX records/)
    end

    it "raises a ProviderError with DreamHost's message, field details, and missing permissions" do
      stubs.post("/v1/dns/example.com") do
        body = { code: "forbidden", message: "Insufficient permissions.", correlationId: "abc",
                 details: [{ field: "records[0].name", code: "invalid_value", message: "Must be valid." }],
                 requiredPermissions: ["dns:write"] }
        [403, {}, body.to_json]
      end

      expect do
        provider.create_record(zone: "example.com", name: "www", type: "A", value: "1.2.3.4")
      end.to raise_error(Denise::ProviderError) { |e|
        expect(e.message).to include("Insufficient permissions.")
        expect(e.message).to include("records[0].name: Must be valid.")
        expect(e.message).to include("needs permission dns:write")
      }
    end

    it "raises a ProviderError for a non-JSON response (e.g. an nginx 503 page)" do
      stubs.post("/v1/dns/example.com") { [503, {}, "<html>503 Service Temporarily Unavailable</html>"] }

      expect do
        provider.create_record(zone: "example.com", name: "www", type: "A", value: "1.2.3.4")
      end.to raise_error(Denise::ProviderError, /unparseable response \(HTTP 503\)/)
    end
  end

  describe "#delete_record" do
    it "looks up the record's canonical value, then DELETEs it by name/type/value" do
      stubs.get("/v1/dns/example.com") do
        [200, {}, { data: [record("www", "A", "1.2.3.4"), record("www", "TXT", "hello")] }.to_json]
      end
      stubs.delete("/v1/dns/example.com") do |env|
        expect(json_body(env)).to eq("record" => { "name" => "www", "type" => "A", "value" => "1.2.3.4" })
        expect(env.request_headers["Idempotency-Key"]).not_to be_nil
        [202, {}, task("success")]
      end

      provider.delete_record(zone: "example.com", name: "www", type: "A")
    end

    it "raises a ProviderError when no matching record exists" do
      stubs.get("/v1/dns/example.com") { [200, {}, { data: [] }.to_json] }

      expect do
        provider.delete_record(zone: "example.com", name: "missing", type: "A")
      end.to raise_error(Denise::ProviderError, /no A record named 'missing'/)
    end

    it "refuses to guess when the name has several records of that type" do
      stubs.get("/v1/dns/example.com") do
        [200, {}, { data: [record("@", "TXT", "one"), record("@", "TXT", "two")] }.to_json]
      end

      expect do
        provider.delete_record(zone: "example.com", name: "@", type: "TXT")
      end.to raise_error(Denise::ProviderError, /2 TXT records \(one, two\)/)
    end

    it "refuses records DreamHost manages itself" do
      stubs.get("/v1/dns/example.com") do
        [200, {}, { data: [record("www", "A", "1.2.3.4", protected: true)] }.to_json]
      end

      expect do
        provider.delete_record(zone: "example.com", name: "www", type: "A")
      end.to raise_error(Denise::ProviderError, /managed by DreamHost \(hosting\)/)
    end
  end

  describe "#list_records" do
    it "returns the zone's records with relative names and no ttl" do
      stubs.get("/v1/dns/example.com") do
        [200, {}, { data: [record("www", "A", "1.2.3.4"), record("@", "TXT", "v=spf1 -all")] }.to_json]
      end

      expect(provider.list_records(zone: "example.com")).to eq(
        [
          { "name" => "www", "type" => "A", "value" => "1.2.3.4", "ttl" => nil },
          { "name" => "@", "type" => "TXT", "value" => "v=spf1 -all", "ttl" => nil }
        ]
      )
    end
  end

  describe "#list_zones" do
    it "returns every website's domain, following offset pagination" do
      stubs.get("/v1/websites") do |env|
        expect(env.params["limit"]).to eq("100")
        expect(env.params["offset"]).to eq("0")
        [200, {}, { data: [{ domain: "a.com", type: "hosted" }, { domain: "b.com", type: "dns_only" }],
                    meta: { limit: 100, offset: 0, total: 3 } }.to_json]
      end
      stubs.get("/v1/websites") do |env|
        expect(env.params["offset"]).to eq("2")
        [200, {}, { data: [{ domain: "c.com", type: "parked" }], meta: { limit: 100, offset: 2, total: 3 } }.to_json]
      end

      expect(provider.list_zones).to eq(%w[a.com b.com c.com])
    end

    it "drops subdomain websites whose parent domain is also listed" do
      stubs.get("/v1/websites") do
        sites = %w[example.com files.example.com www.files.example.com sub.other.com notexample.com]
        [200, {}, { data: sites.map { |d| { domain: d, type: "hosted" } },
                    meta: { limit: 100, offset: 0, total: 5 } }.to_json]
      end

      expect(provider.list_zones).to eq(%w[example.com sub.other.com notexample.com])
    end
  end

  describe "verbose logging" do
    let(:secret_provider) { described_class.new(token: "super-secret-dh-key-xyz", connection: connection) }

    it "logs method/path/body and the response when Denise.verbose is true, without the API key" do
      Denise.verbose = true
      stubs.post("/v1/dns/example.com") { [202, {}, task("success")] }

      output = capture_stderr do
        secret_provider.create_record(zone: "example.com", name: "www", type: "A", value: "1.2.3.4")
      end

      expect(output).to include("POST dns/example.com")
      expect(output).to include("1.2.3.4")
      expect(output).to include("HTTP 202")
      expect(output).not_to include("super-secret-dh-key-xyz")
    end

    it "logs nothing when Denise.verbose is false" do
      stubs.get("/v1/dns/example.com") { [200, {}, { data: [] }.to_json] }

      output = capture_stderr { secret_provider.list_records(zone: "example.com") }

      expect(output).to eq("")
    end
  end

  it_behaves_like "a provider that wraps network errors", "super-secret-dh-key-xyz", ["super-secret-dh-key-xyz"]
end
