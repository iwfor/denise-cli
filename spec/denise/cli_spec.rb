# frozen_string_literal: true

require "json"

RSpec.describe Denise::CLI do
  before do
    config = Denise::Config.new
    config.add_source(provider: "dreamhost", token: "t1", alias_name: "dh", default: true)
    config.add_zone("example.com", provider_alias: "dh")
  end

  describe "add-record" do
    it "creates the record through the provider" do
      client = instance_double(Denise::Providers::Dreamhost)
      allow(Denise::Providers).to receive(:client_for).with("dreamhost", token: "t1").and_return(client)
      expect(client).to receive(:create_record)
        .with(zone: "example.com", name: "www", type: "A", value: "1.2.3.4", ttl: nil)

      silence_output { described_class.start(%w[add-record www --type A --value 1.2.3.4 -z example.com]) }
    end

    it "exits with an error when the provider call fails" do
      client = instance_double(Denise::Providers::Dreamhost)
      allow(Denise::Providers).to receive(:client_for).and_return(client)
      allow(client).to receive(:create_record).and_raise(Denise::ProviderError, "boom")

      expect do
        silence_output { described_class.start(%w[add-record www --type A --value 1.2.3.4 -z example.com]) }
      end.to raise_error(SystemExit)
    end

    it "infers type A from an IPv4 --value when --type is omitted" do
      client = instance_double(Denise::Providers::Dreamhost)
      allow(Denise::Providers).to receive(:client_for).with("dreamhost", token: "t1").and_return(client)
      expect(client).to receive(:create_record)
        .with(zone: "example.com", name: "www", type: "A", value: "1.2.3.4", ttl: nil)

      silence_output { described_class.start(%w[add-record www --value 1.2.3.4 -z example.com]) }
    end

    it "infers type AAAA from an IPv6 --value when --type is omitted" do
      client = instance_double(Denise::Providers::Dreamhost)
      allow(Denise::Providers).to receive(:client_for).with("dreamhost", token: "t1").and_return(client)
      expect(client).to receive(:create_record)
        .with(zone: "example.com", name: "www", type: "AAAA", value: "2001:db8::1", ttl: nil)

      silence_output { described_class.start(%w[add-record www --value 2001:db8::1 -z example.com]) }
    end

    it "exits with an error when --type is omitted and --value isn't an IP address" do
      expect(Denise::Providers).not_to receive(:client_for)

      expect do
        silence_output { described_class.start(%w[add-record www --value target.example.com -z example.com]) }
      end.to raise_error(SystemExit)
    end

    it "exits with an error when the zone isn't tracked locally under the resolved provider" do
      expect(Denise::Providers).not_to receive(:client_for)

      expect do
        silence_output { described_class.start(%w[add-record www --value 1.2.3.4 -z untracked.com]) }
      end.to raise_error(SystemExit)
    end

    it "logs the change to records.log after the record is created" do
      client = instance_double(Denise::Providers::Dreamhost)
      allow(Denise::Providers).to receive(:client_for).with("dreamhost", token: "t1").and_return(client)
      allow(client).to receive(:create_record)

      silence_output { described_class.start(%w[add-record www --type A --value 1.2.3.4 -z example.com]) }

      entry = JSON.parse(File.readlines(Denise::Paths.records_log_file, chomp: true).last)
      expect(entry).to include(
        "provider" => "dreamhost", "alias" => "dh", "action" => "add", "zone" => "example.com",
        "name" => "www", "type" => "A", "value" => "1.2.3.4"
      )
    end

    it "does not log to records.log when the provider call fails" do
      client = instance_double(Denise::Providers::Dreamhost)
      allow(Denise::Providers).to receive(:client_for).and_return(client)
      allow(client).to receive(:create_record).and_raise(Denise::ProviderError, "boom")

      expect do
        silence_output { described_class.start(%w[add-record www --type A --value 1.2.3.4 -z example.com]) }
      end.to raise_error(SystemExit)

      expect(File.exist?(Denise::Paths.records_log_file)).to be(false)
    end
  end

  describe "list-records" do
    it "lists records from a live query to the provider" do
      client = instance_double(Denise::Providers::Dreamhost)
      allow(Denise::Providers).to receive(:client_for).with("dreamhost", token: "t1").and_return(client)
      allow(client).to receive(:list_records).with(zone: "example.com")
                                             .and_return([{ "name" => "www", "type" => "A", "value" => "1.2.3.4",
                                                            "ttl" => 300 }])

      output = capture_stdout { described_class.start(%w[list-records -z example.com]) }

      expect(output).to include("www")
      expect(output).to include("1.2.3.4")
    end

    it "prints no trailing padding and drops the TTL column when no record has one" do
      client = instance_double(Denise::Providers::Dreamhost)
      allow(Denise::Providers).to receive(:client_for).and_return(client)
      allow(client).to receive(:list_records).with(zone: "example.com")
                                             .and_return([{ "name" => "www", "type" => "A", "value" => "1.2.3.4",
                                                            "ttl" => nil },
                                                          { "name" => "dkim", "type" => "TXT",
                                                            "value" => "v=DKIM1; #{'p' * 200}", "ttl" => nil }])

      output = capture_stdout { described_class.start(%w[list-records -z example.com]) }

      expect(output.lines.map(&:chomp)).to all(satisfy { |line| line == line.rstrip })
      expect(output).not_to include("TTL")
      expect(output.lines.first.chomp).to eq("NAME  TYPE  VALUE")
    end

    it "reports when there are no records" do
      client = instance_double(Denise::Providers::Dreamhost)
      allow(Denise::Providers).to receive(:client_for).and_return(client)
      allow(client).to receive(:list_records).and_return([])

      output = capture_stdout { described_class.start(%w[list-records -z example.com]) }

      expect(output).to include("No records found for 'example.com'")
    end

    it "exits with an error when the zone isn't tracked locally" do
      expect(Denise::Providers).not_to receive(:client_for)

      expect do
        silence_output { described_class.start(%w[list-records -z untracked.com]) }
      end.to raise_error(SystemExit)
    end

    it "shows a PROXIED column for providers that report it" do
      client = instance_double(Denise::Providers::Dreamhost)
      allow(Denise::Providers).to receive(:client_for).and_return(client)
      allow(client).to receive(:list_records)
        .and_return([{ "name" => "www", "type" => "CNAME", "value" => "t.example.net", "ttl" => 1, "proxied" => true },
                     { "name" => "mail", "type" => "A", "value" => "1.2.3.4", "ttl" => 1, "proxied" => false }])

      output = capture_stdout { described_class.start(%w[list-records -z example.com]) }

      expect(output.lines.first).to include("PROXIED")
      expect(output.lines[1].chomp).to match(/www .* yes\z/)
      expect(output.lines[2].chomp).to match(/mail .* no\z/)
    end
  end

  describe "--proxied" do
    it "passes proxied: true to a provider that supports it" do
      client = instance_double(Denise::Providers::Cloudflare, supports_proxied?: true)
      allow(Denise::Providers).to receive(:client_for).and_return(client)
      expect(client).to receive(:create_record)
        .with(zone: "example.com", name: "www", type: "CNAME", value: "t.example.net", ttl: nil, proxied: true)

      silence_output do
        described_class.start(%w[add-record www --type CNAME --value t.example.net --proxied -z example.com])
      end
    end

    it "is refused for a provider without a proxy, before any change" do
      client = instance_double(Denise::Providers::Dreamhost, supports_proxied?: false)
      allow(Denise::Providers).to receive(:client_for).and_return(client)
      expect(client).not_to receive(:create_record)

      expect do
        silence_output do
          described_class.start(%w[add-record www --type CNAME --value t.example.net --no-proxied -z example.com])
        end
      end.to raise_error(SystemExit)
    end
  end

  describe "update-record" do
    let(:client) { instance_double(Denise::Providers::Cloudflare, supports_proxied?: true) }
    let(:old) { { "name" => "www", "type" => "CNAME", "value" => "old.example.net", "ttl" => 1, "proxied" => true } }

    before do
      allow(Denise::Providers).to receive(:client_for).and_return(client)
      allow(client).to receive(:list_records).with(zone: "example.com").and_return([old])
    end

    it "updates in place, leaving proxied alone unless asked, and logs old and new values" do
      expect(client).to receive(:update_record)
        .with(zone: "example.com", name: "www", type: "CNAME", value: "new.example.net", ttl: nil, old_value: nil)
        .and_return(old.merge("value" => "new.example.net"))

      output = capture_stdout do
        described_class.start(%w[update-record www --value new.example.net -z example.com])
      end

      expect(output).to include("old.example.net -> new.example.net (proxied)")
      entry = JSON.parse(File.readlines(Denise::Paths.records_log_file).last)
      expect(entry).to include("action" => "update", "value" => "new.example.net", "old_value" => "old.example.net")
    end

    it "passes --no-proxied, --ttl and --old-value through" do
      expect(client).to receive(:update_record)
        .with(zone: "example.com", name: "www", type: "CNAME", value: "new.example.net", ttl: 300,
              old_value: "old.example.net", proxied: false)
        .and_return(old.merge("value" => "new.example.net", "proxied" => false))

      silence_output do
        described_class.start(%w[update-record www --value new.example.net --ttl 300 --old-value old.example.net
                                 --no-proxied -z example.com])
      end
    end

    it "exits with an error when the provider can't update in place" do
      dreamhost = Denise::Providers::Dreamhost.new(token: "t1")
      allow(Denise::Providers).to receive(:client_for).and_return(dreamhost)
      allow(dreamhost).to receive(:list_records).and_return([old])

      expect do
        silence_output { described_class.start(%w[update-record www --value new.example.net -z example.com]) }
      end.to raise_error(SystemExit)
    end
  end

  describe "remove-record" do
    it "deletes the record through the provider" do
      client = instance_double(Denise::Providers::Dreamhost)
      allow(Denise::Providers).to receive(:client_for).with("dreamhost", token: "t1").and_return(client)
      allow(client).to receive(:list_records).with(zone: "example.com")
                                             .and_return([{ "name" => "www", "type" => "A", "value" => "1.2.3.4",
                                                            "ttl" => nil }])
      expect(client).to receive(:delete_record).with(zone: "example.com", name: "www", type: "A")

      silence_output { described_class.start(%w[remove-record www --type A -z example.com]) }
    end

    it "exits with an error when the provider's delete call fails" do
      client = instance_double(Denise::Providers::Dreamhost)
      allow(Denise::Providers).to receive(:client_for).and_return(client)
      allow(client).to receive(:list_records)
        .and_return([{ "name" => "www", "type" => "A", "value" => "1.2.3.4", "ttl" => nil }])
      allow(client).to receive(:delete_record).and_raise(Denise::ProviderError, "boom")

      expect do
        silence_output { described_class.start(%w[remove-record www --type A -z example.com]) }
      end.to raise_error(SystemExit)
    end

    it "infers the type from the live listing when the name is unambiguous" do
      client = instance_double(Denise::Providers::Dreamhost)
      allow(Denise::Providers).to receive(:client_for).with("dreamhost", token: "t1").and_return(client)
      allow(client).to receive(:list_records)
        .and_return([{ "name" => "www", "type" => "A", "value" => "1.2.3.4", "ttl" => nil }])
      expect(client).to receive(:delete_record).with(zone: "example.com", name: "www", type: "A")

      silence_output { described_class.start(%w[remove-record www -z example.com]) }
    end

    it "exits with an error and requires --type when the name matches records of multiple types" do
      client = instance_double(Denise::Providers::Dreamhost)
      allow(Denise::Providers).to receive(:client_for).and_return(client)
      allow(client).to receive(:list_records).and_return(
        [
          { "name" => "www", "type" => "A", "value" => "1.2.3.4", "ttl" => nil },
          { "name" => "www", "type" => "AAAA", "value" => "::1", "ttl" => nil }
        ]
      )
      expect(client).not_to receive(:delete_record)

      expect do
        silence_output { described_class.start(%w[remove-record www -z example.com]) }
      end.to raise_error(SystemExit)
    end

    it "exits with an error when --type is omitted and no record matches the name" do
      client = instance_double(Denise::Providers::Dreamhost)
      allow(Denise::Providers).to receive(:client_for).and_return(client)
      allow(client).to receive(:list_records).and_return([])
      expect(client).not_to receive(:delete_record)

      expect do
        silence_output { described_class.start(%w[remove-record missing -z example.com]) }
      end.to raise_error(SystemExit)
    end

    it "exits with an error when an explicit --type doesn't match any live record" do
      client = instance_double(Denise::Providers::Dreamhost)
      allow(Denise::Providers).to receive(:client_for).and_return(client)
      allow(client).to receive(:list_records)
        .and_return([{ "name" => "www", "type" => "A", "value" => "1.2.3.4", "ttl" => nil }])
      expect(client).not_to receive(:delete_record)

      expect do
        silence_output { described_class.start(%w[remove-record www --type AAAA -z example.com]) }
      end.to raise_error(SystemExit)
    end

    it "exits with an error when the zone isn't tracked locally" do
      expect(Denise::Providers).not_to receive(:client_for)

      expect do
        silence_output { described_class.start(%w[remove-record www --type A -z untracked.com]) }
      end.to raise_error(SystemExit)
    end

    it "logs the change to records.log after the record is removed" do
      client = instance_double(Denise::Providers::Dreamhost)
      allow(Denise::Providers).to receive(:client_for).with("dreamhost", token: "t1").and_return(client)
      allow(client).to receive(:list_records)
        .and_return([{ "name" => "www", "type" => "A", "value" => "1.2.3.4", "ttl" => nil }])
      allow(client).to receive(:delete_record)

      silence_output { described_class.start(%w[remove-record www --type A -z example.com]) }

      entry = JSON.parse(File.readlines(Denise::Paths.records_log_file, chomp: true).last)
      expect(entry).to include(
        "provider" => "dreamhost", "alias" => "dh", "action" => "remove", "zone" => "example.com",
        "name" => "www", "type" => "A", "value" => "1.2.3.4"
      )
    end

    it "does not log to records.log when the provider's delete call fails" do
      client = instance_double(Denise::Providers::Dreamhost)
      allow(Denise::Providers).to receive(:client_for).and_return(client)
      allow(client).to receive(:list_records)
        .and_return([{ "name" => "www", "type" => "A", "value" => "1.2.3.4", "ttl" => nil }])
      allow(client).to receive(:delete_record).and_raise(Denise::ProviderError, "boom")

      expect do
        silence_output { described_class.start(%w[remove-record www --type A -z example.com]) }
      end.to raise_error(SystemExit)

      expect(File.exist?(Denise::Paths.records_log_file)).to be(false)
    end
  end

  describe "list-providers" do
    it "lists configured provider sources" do
      output = capture_stdout { described_class.start(%w[list-providers]) }

      expect(output).to include("dh")
      expect(output).to include("dreamhost")
    end

    it "is also invocable as list-sources" do
      output = capture_stdout { described_class.start(%w[list-sources]) }

      expect(output).to include("dh")
      expect(output).to include("dreamhost")
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

  describe "update-token" do
    it "replaces the source's token from --token" do
      output = capture_stdout { described_class.start(%w[update-token dh --token new-secret]) }

      expect(output).to include("Updated token for 'dh'")
      expect(Denise::Config.new.token_for("dh")).to eq("new-secret")
    end

    it "prompts for the token without echo when --token is omitted on a terminal" do
      allow($stdin).to receive_messages(tty?: true, noecho: "prompted-secret\n")

      silence_output { described_class.start(%w[update-token dh]) }

      expect(Denise::Config.new.token_for("dh")).to eq("prompted-secret")
    end

    it "reads the token from piped stdin, without prompting, when stdin isn't a terminal" do
      allow($stdin).to receive_messages(tty?: false, gets: "piped-secret\n")

      output = capture_stdout { described_class.start(%w[update-token dh]) }

      expect(output).not_to include("API token:")
      expect(Denise::Config.new.token_for("dh")).to eq("piped-secret")
    end

    it "fails for an unknown alias" do
      expect do
        silence_output { described_class.start(%w[update-token nope --token x]) }
      end.to raise_error(SystemExit)
    end

    it "fails on a blank token and keeps the old one" do
      allow($stdin).to receive_messages(tty?: true, noecho: "\n")

      expect do
        silence_output { described_class.start(%w[update-token dh]) }
      end.to raise_error(SystemExit)
      expect(Denise::Config.new.token_for("dh")).to eq("t1")
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

  describe "search" do
    it "finds matches under the default provider when -p is omitted" do
      client = instance_double(Denise::Providers::Dreamhost)
      allow(Denise::Providers).to receive(:client_for).with("dreamhost", token: "t1").and_return(client)
      allow(client).to receive(:list_records).with(zone: "example.com")
                                             .and_return([{ "name" => "www", "type" => "A", "value" => "1.2.3.4",
                                                            "ttl" => nil }])

      output = capture_stdout { described_class.start(%w[search www]) }

      expect(output).to include("dh")
      expect(output).to include("example.com")
      expect(output).to include("1.2.3.4")
    end

    it "reports no matches for a query that doesn't hit anything" do
      client = instance_double(Denise::Providers::Dreamhost)
      allow(Denise::Providers).to receive(:client_for).and_return(client)
      allow(client).to receive(:list_records).and_return([])

      output = capture_stdout { described_class.start(%w[search nonesuch]) }

      expect(output).to include("No matches for 'nonesuch'")
    end

    it "searches every provider with the virtual alias -p all" do
      Denise::Config.new.add_source(provider: "cloudflare", token: "cftok", alias_name: "cf")
      Denise::Config.new.add_zone("other.com", provider_alias: "cf")

      dh_client = instance_double(Denise::Providers::Dreamhost)
      cf_client = instance_double(Denise::Providers::Cloudflare)
      allow(Denise::Providers).to receive(:client_for).with("dreamhost", token: "t1").and_return(dh_client)
      allow(Denise::Providers).to receive(:client_for).with("cloudflare", token: "cftok").and_return(cf_client)
      allow(dh_client).to receive(:list_records).and_return([])
      allow(cf_client).to receive(:list_records).with(zone: "other.com")
                                                .and_return([{ "name" => "app", "type" => "A", "value" => "5.6.7.8",
                                                               "ttl" => nil }])

      output = capture_stdout { described_class.start(%w[search app -p all]) }

      expect(output).to include("cf")
      expect(output).to include("other.com")
    end

    it "continues past a per-zone failure and still returns matches from other zones" do
      Denise::Config.new.add_zone("second.com", provider_alias: "dh")

      client = instance_double(Denise::Providers::Dreamhost)
      allow(Denise::Providers).to receive(:client_for).with("dreamhost", token: "t1").and_return(client)
      allow(client).to receive(:list_records).with(zone: "example.com").and_raise(Denise::ProviderError, "boom")
      allow(client).to receive(:list_records).with(zone: "second.com")
                                             .and_return([{ "name" => "www", "type" => "A", "value" => "1.2.3.4",
                                                            "ttl" => nil }])

      stdout = nil
      stderr = capture_stderr { stdout = capture_stdout { described_class.start(%w[search www]) } }

      expect(stdout).to include("second.com")
      expect(stderr).to include("boom")
    end

    it "restricts matches to the categories given in --limit" do
      client = instance_double(Denise::Providers::Dreamhost)
      allow(Denise::Providers).to receive(:client_for).and_return(client)
      allow(client).to receive(:list_records)
        .and_return([{ "name" => "www", "type" => "A", "value" => "1.2.3.4", "ttl" => nil }])

      output = capture_stdout { described_class.start(%w[search 1.2.3.4 --limit zones,names]) }

      expect(output).to include("No matches for '1.2.3.4'")
    end

    it "exits with an error for an unknown --limit category" do
      expect do
        silence_output { described_class.start(%w[search www --limit bogus]) }
      end.to raise_error(SystemExit)
    end

    it "exits with an error for an unknown -p alias" do
      expect do
        silence_output { described_class.start(%w[search www -p nope]) }
      end.to raise_error(SystemExit)
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
      expect(output).to include('zones = [ "example.com" ]')
    end
  end

  describe "help" do
    it "shows a header and documents --completions and -h/--help when no command is given" do
      output = capture_stdout { described_class.start(["help"]) }

      expect(output).to include("DeNiSe CLI")
      expect(output).to include("--completions")
      expect(output).to include("-h, --help")
    end

    it "shows the same header for the bare invocation (no arguments)" do
      output = capture_stdout { described_class.start([]) }

      expect(output).to include("DeNiSe CLI")
      expect(output).to include("--completions")
      expect(output).to include("-h, --help")
    end

    it "does not repeat the header, --completions, or -h/--help for a specific command" do
      output = capture_stdout { described_class.start(%w[help version]) }

      expect(output).not_to include("DeNiSe CLI")
      expect(output).not_to include("--completions")
      expect(output).not_to include("-h, --help")
    end

    it "responds to -h the same as help" do
      output = capture_stdout { described_class.start(["-h"]) }

      expect(output).to include("DeNiSe CLI")
    end

    it "shows a command's own help for `command -h`, instead of running it" do
      expect(Denise::Providers).not_to receive(:client_for)

      output = capture_stdout { described_class.start(%w[add-record -h]) }

      expect(output).to include("Usage:")
      expect(output).to include("Add a DNS record to a zone")
    end

    it "shows a command's own help for `command --help`, instead of running it" do
      expect(Denise::Providers).not_to receive(:client_for)

      output = capture_stdout { described_class.start(%w[add-record --help]) }

      expect(output).to include("Usage:")
      expect(output).to include("Add a DNS record to a zone")
    end

    it "finds -h/--help wherever it appears among a command's other args" do
      expect(Denise::Providers).not_to receive(:client_for)

      output = capture_stdout do
        described_class.start(%w[add-record www --type A --value 1.2.3.4 -z example.com -h])
      end

      expect(output).to include("Usage:")
      expect(output).to include("Add a DNS record to a zone")
    end
  end

  describe "an unknown command" do
    it "suggests the hyphenated command form, not Thor's internal underscored method name" do
      output = capture_stderr do
        expect { described_class.start(%w[list-record]) }.to raise_error(SystemExit)
      end

      expect(output).to include('"list-records"')
      expect(output).not_to include("list_records")
    end
  end
end
