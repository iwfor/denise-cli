# frozen_string_literal: true

require "faraday"
require "rexml/document"
require "openssl"
require "time"

module Denise
  module Providers
    # AWS Route 53 (https://docs.aws.amazon.com/Route53/latest/APIReference/).
    #
    # AWS auth is a signature (SigV4) over the whole request, not a bearer
    # token, so it needs two secrets. There's no separate credential storage
    # in denise's config model, so the token field doubles up:
    # ACCESS_KEY_ID:SECRET_ACCESS_KEY. Route 53 is a global service, but
    # SigV4 still requires a region for the signing scope; AWS's convention
    # for Route 53 is the fixed pseudo-region "us-east-1".
    class Aws < Base
      REGION = "us-east-1"
      SERVICE = "route53"
      HOST = "route53.amazonaws.com"
      API_PATH_PREFIX = "/2013-04-01/"
      API_URL = "https://#{HOST}#{API_PATH_PREFIX}".freeze
      XMLNS = "https://route53.amazonaws.com/doc/2013-04-01/"
      DEFAULT_TTL = 300

      def initialize(token:, connection: nil)
        super
        @access_key_id, @secret_access_key = token.to_s.split(":", 2)
        return if @access_key_id && @secret_access_key && !@access_key_id.empty? && !@secret_access_key.empty?

        raise ProviderError, "AWS token must be in the form ACCESS_KEY_ID:SECRET_ACCESS_KEY"
      end

      def create_record(zone:, name:, type:, value:, ttl: nil)
        change_record("CREATE", zone: zone, name: name, type: type, value: value, ttl: ttl || DEFAULT_TTL)
      end

      def delete_record(zone:, name:, type:)
        record = list_records(zone: zone).find { |r| r["name"] == name && r["type"] == type }
        raise ProviderError, "no #{type} record named '#{name}' found in zone '#{zone}'" unless record

        change_record("DELETE", zone: zone, name: name, type: type, value: record["value"], ttl: record["ttl"])
      end

      def list_records(zone:)
        doc = request(:get, "hostedzone/#{zone_id(zone)}/rrset")
        doc.get_elements("//ResourceRecordSets/ResourceRecordSet").map do |rrset|
          {
            "name" => unqualify(rrset.text("Name"), zone),
            "type" => rrset.text("Type"),
            "value" => rrset.get_elements("ResourceRecords/ResourceRecord/Value").first&.text,
            "ttl" => rrset.text("TTL")&.to_i
          }
        end
      end

      def list_zones
        zones = []
        marker = nil
        loop do
          doc = request(:get, "hostedzone", params: marker ? { marker: marker } : nil)
          doc.get_elements("//HostedZones/HostedZone").each { |hz| zones << hz.text("Name").delete_suffix(".") }

          break unless doc.get_elements("//IsTruncated").first&.text == "true"

          marker = doc.get_elements("//NextMarker").first&.text
          break unless marker
        end
        zones
      end

      private

      def change_record(action, zone:, name:, type:, value:, ttl:)
        body = change_batch_xml(action, name: fqdn(zone, name), type: type, value: value, ttl: ttl)
        request(:post, "hostedzone/#{zone_id(zone)}/rrset", body: body)
      end

      def change_batch_xml(action, name:, type:, value:, ttl:)
        doc = REXML::Document.new
        root = doc.add_element("ChangeResourceRecordSetsRequest", "xmlns" => XMLNS)
        change = root.add_element("ChangeBatch").add_element("Changes").add_element("Change")
        change.add_element("Action").add_text(action)
        rrset = change.add_element("ResourceRecordSet")
        rrset.add_element("Name").add_text(name)
        rrset.add_element("Type").add_text(type)
        rrset.add_element("TTL").add_text(ttl.to_s)
        rrset.add_element("ResourceRecords").add_element("ResourceRecord").add_element("Value").add_text(value)

        String.new.tap { |out| doc.write(out) }
      end

      def zone_id(zone)
        @zone_ids ||= {}
        @zone_ids[zone] ||= begin
          doc = request(:get, "hostedzonesbyname", params: { dnsname: zone })
          hosted_zone = doc.get_elements("//HostedZones/HostedZone").first
          unless hosted_zone && hosted_zone.text("Name") == "#{zone}."
            raise ProviderError, "no AWS Route 53 zone named '#{zone}'"
          end

          hosted_zone.text("Id").delete_prefix("/hostedzone/")
        end
      end

      def fqdn(zone, name)
        base = name.to_s.empty? || name == "@" ? zone : "#{name}.#{zone}"
        "#{base}."
      end

      def unqualify(record, zone)
        bare = record.to_s.delete_suffix(".")
        bare == zone ? "@" : bare.delete_suffix(".#{zone}")
      end

      # params/body here are only ever zone names, record names/types/values,
      # and pagination markers - never the Authorization/X-Amz-Date headers
      # signed_headers computes, so it's always safe to log in full.
      def request(method, path, params: nil, body: nil)
        query = params ? "?#{params.map { |k, v| "#{k}=#{v}" }.join('&')}" : ""
        log("#{method.to_s.upcase} #{path}#{query}#{" body=#{body}" if body}")

        response = perform do
          connection.public_send(method) do |req|
            req.url(path, params || {})
            signed_headers(method, path, params: params, body: body).each { |k, v| req.headers[k] = v }
            req.headers["Content-Type"] = "application/xml" if body
            req.body = body if body
          end
        end
        log("-> HTTP #{response.status}")
        parse(response)
      end

      def secrets
        super + [@secret_access_key]
      end

      def build_connection
        Faraday.new(url: API_URL) { |f| f.adapter Faraday.default_adapter }
      end

      # AWS Signature Version 4: https://docs.aws.amazon.com/IAM/latest/UserGuide/create-signed-request.html
      def signed_headers(method, path, params:, body:)
        now = Time.now.utc
        amz_date = now.strftime("%Y%m%dT%H%M%SZ")
        date_stamp = now.strftime("%Y%m%d")

        canonical_request = [
          method.to_s.upcase,
          "#{API_PATH_PREFIX}#{path}",
          canonical_query_string(params),
          "host:#{HOST}\nx-amz-date:#{amz_date}\n",
          "host;x-amz-date",
          OpenSSL::Digest::SHA256.hexdigest(body || "")
        ].join("\n")

        credential_scope = "#{date_stamp}/#{REGION}/#{SERVICE}/aws4_request"
        string_to_sign = [
          "AWS4-HMAC-SHA256",
          amz_date,
          credential_scope,
          OpenSSL::Digest::SHA256.hexdigest(canonical_request)
        ].join("\n")

        signature = OpenSSL::HMAC.hexdigest("SHA256", signing_key(date_stamp), string_to_sign)
        authorization = "AWS4-HMAC-SHA256 Credential=#{@access_key_id}/#{credential_scope}, " \
                        "SignedHeaders=host;x-amz-date, Signature=#{signature}"

        { "Host" => HOST, "X-Amz-Date" => amz_date, "Authorization" => authorization }
      end

      def signing_key(date_stamp)
        k_date = OpenSSL::HMAC.digest("SHA256", "AWS4#{@secret_access_key}", date_stamp)
        k_region = OpenSSL::HMAC.digest("SHA256", k_date, REGION)
        k_service = OpenSSL::HMAC.digest("SHA256", k_region, SERVICE)
        OpenSSL::HMAC.digest("SHA256", k_service, "aws4_request")
      end

      # Only ever called with simple hostname values (zone names), which
      # contain no characters RFC 3986 unreserved encoding would change -
      # safe to also hand to Faraday for the actual request's query string.
      def canonical_query_string(params)
        return "" unless params && !params.empty?

        params.map { |k, v| "#{uri_encode(k)}=#{uri_encode(v)}" }.sort.join("&")
      end

      def uri_encode(value)
        value.to_s.each_byte.map do |byte|
          char = byte.chr
          char =~ /[A-Za-z0-9\-._~]/ ? char : format("%%%02X", byte)
        end.join
      end

      def parse(response)
        doc = REXML::Document.new(response.body.to_s)
        return doc if response.status < 400

        error = doc.get_elements("//Error").first
        detail = error ? "#{error.text('Code')}: #{error.text('Message')}" : "HTTP #{response.status}"
        raise ProviderError, "AWS API error: #{detail}"
      rescue REXML::ParseException
        raise ProviderError, "AWS API returned an unparseable response (HTTP #{response.status})"
      end
    end
  end
end
