# frozen_string_literal: true

require "rexml/document"

RSpec.describe Denise::Providers::Aws do
  let(:zone_lookup_xml) do
    <<~XML
      <ListHostedZonesByNameResponse xmlns="https://route53.amazonaws.com/doc/2013-04-01/">
        <HostedZones>
          <HostedZone>
            <Id>/hostedzone/Z1PA6795UKMFR9</Id>
            <Name>example.com.</Name>
          </HostedZone>
        </HostedZones>
      </ListHostedZonesByNameResponse>
    XML
  end

  describe "#initialize" do
    it "rejects a token with no colon" do
      expect { described_class.new(token: "no-colon-here") }
        .to raise_error(Denise::ProviderError, /ACCESS_KEY_ID:SECRET_ACCESS_KEY/)
    end

    it "rejects a token missing the secret half" do
      expect { described_class.new(token: "AKIDEXAMPLE:") }
        .to raise_error(Denise::ProviderError, /ACCESS_KEY_ID:SECRET_ACCESS_KEY/)
    end
  end

  describe "SigV4 signing" do
    # Independently re-derives the expected Authorization header straight
    # from AWS's published algorithm (not by calling any private helper on
    # the class under test) and compares against what #signed_headers
    # produced, so a bug in the implementation can't accidentally agree
    # with itself the way self-consistent stubs did for the Cloudflare
    # client (see CLAUDE.md).
    it "produces an Authorization header matching an independently computed signature" do
      provider = described_class.new(token: "AKIDEXAMPLE:wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")

      headers = provider.send(:signed_headers, :get, "hostedzone/Z1PA6795UKMFR9/rrset", params: nil, body: nil)

      expect(headers["Host"]).to eq("route53.amazonaws.com")
      expect(headers["X-Amz-Date"]).to match(/\A\d{8}T\d{6}Z\z/)

      date_stamp = headers["X-Amz-Date"][0, 8]
      canonical_request = [
        "GET",
        "/2013-04-01/hostedzone/Z1PA6795UKMFR9/rrset",
        "",
        "host:route53.amazonaws.com\nx-amz-date:#{headers['X-Amz-Date']}\n",
        "host;x-amz-date",
        OpenSSL::Digest::SHA256.hexdigest("")
      ].join("\n")
      string_to_sign = [
        "AWS4-HMAC-SHA256",
        headers["X-Amz-Date"],
        "#{date_stamp}/us-east-1/route53/aws4_request",
        OpenSSL::Digest::SHA256.hexdigest(canonical_request)
      ].join("\n")

      k_date = OpenSSL::HMAC.digest("SHA256", "AWS4wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", date_stamp)
      k_region = OpenSSL::HMAC.digest("SHA256", k_date, "us-east-1")
      k_service = OpenSSL::HMAC.digest("SHA256", k_region, "route53")
      k_signing = OpenSSL::HMAC.digest("SHA256", k_service, "aws4_request")
      expected_signature = OpenSSL::HMAC.hexdigest("SHA256", k_signing, string_to_sign)

      expect(headers["Authorization"]).to eq(
        "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/#{date_stamp}/us-east-1/route53/aws4_request, " \
        "SignedHeaders=host;x-amz-date, Signature=#{expected_signature}"
      )
    end
  end

  describe "HTTP behavior" do
    let(:stubs) { Faraday::Adapter::Test::Stubs.new }
    let(:connection) { Faraday.new(url: described_class::API_URL) { |f| f.adapter :test, stubs } }
    let(:provider) { described_class.new(token: "AKIDEXAMPLE:secret", connection: connection) }

    after { stubs.verify_stubbed_calls }

    describe "#create_record" do
      it "looks up the hosted zone id then posts a CREATE change batch" do
        stubs.get("/2013-04-01/hostedzonesbyname") do |env|
          expect(env.params["dnsname"]).to eq("example.com")
          [200, {}, zone_lookup_xml]
        end
        stubs.post("/2013-04-01/hostedzone/Z1PA6795UKMFR9/rrset") do |env|
          expect(env.request_headers["Authorization"]).to match(/\AAWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/)
          doc = REXML::Document.new(env.body)
          expect(doc.get_elements("//Action").first.text).to eq("CREATE")
          expect(doc.get_elements("//Name").first.text).to eq("www.example.com.")
          expect(doc.get_elements("//Type").first.text).to eq("A")
          expect(doc.get_elements("//TTL").first.text).to eq("300")
          expect(doc.get_elements("//Value").first.text).to eq("1.2.3.4")
          [200, {}, "<ChangeResourceRecordSetsResponse/>"]
        end

        provider.create_record(zone: "example.com", name: "www", type: "A", value: "1.2.3.4")
      end

      it "raises a ProviderError when no matching zone exists" do
        stubs.get("/2013-04-01/hostedzonesbyname") do
          body = <<~XML
            <ListHostedZonesByNameResponse xmlns="https://route53.amazonaws.com/doc/2013-04-01/">
              <HostedZones/>
            </ListHostedZonesByNameResponse>
          XML
          [200, {}, body]
        end

        expect do
          provider.create_record(zone: "nope.com", name: "www", type: "A", value: "1.2.3.4")
        end.to raise_error(Denise::ProviderError, /no AWS Route 53 zone named 'nope.com'/)
      end

      it "raises a ProviderError with AWS's error message on failure" do
        stubs.get("/2013-04-01/hostedzonesbyname") { [200, {}, zone_lookup_xml] }
        stubs.post("/2013-04-01/hostedzone/Z1PA6795UKMFR9/rrset") do
          body = <<~XML
            <ErrorResponse xmlns="https://route53.amazonaws.com/doc/2013-04-01/">
              <Error><Type>Sender</Type><Code>InvalidInput</Code><Message>bad ttl</Message></Error>
            </ErrorResponse>
          XML
          [400, {}, body]
        end

        expect do
          provider.create_record(zone: "example.com", name: "www", type: "A", value: "1.2.3.4")
        end.to raise_error(Denise::ProviderError, /InvalidInput: bad ttl/)
      end
    end

    describe "#delete_record" do
      it "looks up the current record then issues a DELETE with its exact ttl/value" do
        stubs.get("/2013-04-01/hostedzonesbyname") { [200, {}, zone_lookup_xml] }
        stubs.get("/2013-04-01/hostedzone/Z1PA6795UKMFR9/rrset") do
          body = <<~XML
            <ListResourceRecordSetsResponse xmlns="https://route53.amazonaws.com/doc/2013-04-01/">
              <ResourceRecordSets>
                <ResourceRecordSet>
                  <Name>www.example.com.</Name>
                  <Type>A</Type>
                  <TTL>600</TTL>
                  <ResourceRecords><ResourceRecord><Value>1.2.3.4</Value></ResourceRecord></ResourceRecords>
                </ResourceRecordSet>
              </ResourceRecordSets>
            </ListResourceRecordSetsResponse>
          XML
          [200, {}, body]
        end
        stubs.post("/2013-04-01/hostedzone/Z1PA6795UKMFR9/rrset") do |env|
          doc = REXML::Document.new(env.body)
          expect(doc.get_elements("//Action").first.text).to eq("DELETE")
          expect(doc.get_elements("//TTL").first.text).to eq("600")
          expect(doc.get_elements("//Value").first.text).to eq("1.2.3.4")
          [200, {}, "<ChangeResourceRecordSetsResponse/>"]
        end

        provider.delete_record(zone: "example.com", name: "www", type: "A")
      end

      it "raises a ProviderError when no matching record exists" do
        stubs.get("/2013-04-01/hostedzonesbyname") { [200, {}, zone_lookup_xml] }
        stubs.get("/2013-04-01/hostedzone/Z1PA6795UKMFR9/rrset") do
          body = <<~XML
            <ListResourceRecordSetsResponse xmlns="https://route53.amazonaws.com/doc/2013-04-01/">
              <ResourceRecordSets/>
            </ListResourceRecordSetsResponse>
          XML
          [200, {}, body]
        end

        expect do
          provider.delete_record(zone: "example.com", name: "missing", type: "A")
        end.to raise_error(Denise::ProviderError, /no A record named 'missing'/)
      end
    end

    describe "#list_records" do
      it "returns normalized records for the zone, using @ for the apex" do
        stubs.get("/2013-04-01/hostedzonesbyname") { [200, {}, zone_lookup_xml] }
        stubs.get("/2013-04-01/hostedzone/Z1PA6795UKMFR9/rrset") do
          body = <<~XML
            <ListResourceRecordSetsResponse xmlns="https://route53.amazonaws.com/doc/2013-04-01/">
              <ResourceRecordSets>
                <ResourceRecordSet>
                  <Name>example.com.</Name>
                  <Type>A</Type>
                  <TTL>300</TTL>
                  <ResourceRecords><ResourceRecord><Value>5.6.7.8</Value></ResourceRecord></ResourceRecords>
                </ResourceRecordSet>
              </ResourceRecordSets>
            </ListResourceRecordSetsResponse>
          XML
          [200, {}, body]
        end

        expect(provider.list_records(zone: "example.com")).to eq(
          [{ "name" => "@", "type" => "A", "value" => "5.6.7.8", "ttl" => 300 }]
        )
      end
    end

    describe "#list_zones" do
      it "returns every hosted zone name on the account, following the Marker pagination" do
        stubs.get("/2013-04-01/hostedzone") do |env|
          body = if env.params["marker"]
                   <<~XML
                     <ListHostedZonesResponse xmlns="https://route53.amazonaws.com/doc/2013-04-01/">
                       <HostedZones>
                         <HostedZone><Name>example.net.</Name></HostedZone>
                       </HostedZones>
                       <IsTruncated>false</IsTruncated>
                     </ListHostedZonesResponse>
                   XML
                 else
                   <<~XML
                     <ListHostedZonesResponse xmlns="https://route53.amazonaws.com/doc/2013-04-01/">
                       <HostedZones>
                         <HostedZone><Name>example.com.</Name></HostedZone>
                       </HostedZones>
                       <IsTruncated>true</IsTruncated>
                       <NextMarker>abc123</NextMarker>
                     </ListHostedZonesResponse>
                   XML
                 end
          [200, {}, body]
        end

        expect(provider.list_zones).to eq(%w[example.com example.net])
      end
    end
  end
end
