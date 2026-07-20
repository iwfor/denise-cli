# frozen_string_literal: true

require "faraday"
require "json"
require "securerandom"

module Denise
  module Providers
    # https://help.dreamhost.com/hc/en-us/articles/217560167-DNS-API-commands
    #
    # DreamHost's API is a single flat command endpoint: every DNS record for
    # every domain on the account comes back from dns-list_records, and there
    # is no zone parameter to add/remove_record, so records are addressed by
    # their fully-qualified name. There is also no TTL parameter — DreamHost
    # manages TTL server-side, so `ttl:` is accepted for interface parity and
    # otherwise ignored.
    class Dreamhost < Base
      API_URL = "https://api.dreamhost.com"

      # rubocop:disable Lint/UnusedMethodArgument -- ttl kept for interface parity; DreamHost has no TTL param
      def create_record(zone:, name:, type:, value:, ttl: nil)
        request("dns-add_record", record: fqdn(zone, name), type: type, value: value)
      end
      # rubocop:enable Lint/UnusedMethodArgument

      def delete_record(zone:, name:, type:)
        record = list_records(zone: zone).find { |r| r["name"] == name && r["type"] == type }
        raise ProviderError, "no #{type} record named '#{name}' found in zone '#{zone}'" unless record

        request("dns-remove_record", record: fqdn(zone, name), type: type, value: record.fetch("value"))
      end

      def list_records(zone:)
        request("dns-list_records").select { |r| r["zone"] == zone }.map do |r|
          { "name" => unqualify(r["record"], zone), "type" => r["type"], "value" => r["value"], "ttl" => nil }
        end
      end

      private

      def fqdn(zone, name)
        name.to_s.empty? || name == "@" ? zone : "#{name}.#{zone}"
      end

      def unqualify(record, zone)
        record == zone ? "@" : record.delete_suffix(".#{zone}")
      end

      def request(cmd, **params)
        query = { key: @token, cmd: cmd, format: "json", unique_id: SecureRandom.uuid }.merge(params)
        response = connection.get("/", query)
        parse(response)
      end

      def build_connection
        Faraday.new(url: API_URL) { |f| f.adapter Faraday.default_adapter }
      end

      def parse(response)
        data = begin
          JSON.parse(response.body)
        rescue JSON::ParserError
          raise ProviderError, "DreamHost API returned an unparseable response (HTTP #{response.status})"
        end

        unless response.success? && data["result"] == "success"
          raise ProviderError, "DreamHost API error: #{data['data'] || response.status}"
        end

        data["data"]
      end
    end
  end
end
