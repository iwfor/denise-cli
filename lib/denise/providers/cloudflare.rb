# frozen_string_literal: true

require "faraday"
require "json"

module Denise
  module Providers
    # https://developers.cloudflare.com/api/operations/dns-records-for-a-zone-list-dns-records
    class Cloudflare < Base
      # Trailing slash matters: Faraday resolves relative request paths
      # against this like a browser resolves a link, so a base path without
      # one gets its last segment (v4) clobbered instead of extended.
      API_URL = "https://api.cloudflare.com/client/v4/"

      def create_record(zone:, name:, type:, value:, ttl: nil)
        body = { type: type, name: name, content: value }
        body[:ttl] = ttl if ttl
        request(:post, "zones/#{zone_id(zone)}/dns_records", body: body)
      end

      def delete_record(zone:, name:, type:)
        record = find_record(zone, name: name, type: type)
        raise ProviderError, "no #{type} record named '#{name}' found in zone '#{zone}'" unless record

        request(:delete, "zones/#{zone_id(zone)}/dns_records/#{record['id']}")
      end

      def list_records(zone:)
        request(:get, "zones/#{zone_id(zone)}/dns_records").fetch("result").map do |r|
          { "name" => r["name"], "type" => r["type"], "value" => r["content"], "ttl" => r["ttl"] }
        end
      end

      def list_zones
        zones = []
        page = 1
        loop do
          data = request(:get, "zones", params: { page: page, per_page: 50 })
          zones.concat(data.fetch("result").map { |z| z["name"] })
          total_pages = data.dig("result_info", "total_pages") || 1
          break if page >= total_pages

          page += 1
        end
        zones
      end

      private

      def find_record(zone, name:, type:)
        result = request(:get, "zones/#{zone_id(zone)}/dns_records", params: { name: name, type: type })
        result.fetch("result").first
      end

      def zone_id(zone)
        @zone_ids ||= {}
        @zone_ids[zone] ||= begin
          result = request(:get, "zones", params: { name: zone }).fetch("result")
          raise ProviderError, "no Cloudflare zone named '#{zone}'" if result.empty?

          result.first.fetch("id")
        end
      end

      # params/body here are only ever zone names, record names/types/values,
      # and IDs - never a token or header, so it's always safe to log in full.
      def request(method, path, params: nil, body: nil)
        query = params ? "?#{params.map { |k, v| "#{k}=#{v}" }.join('&')}" : ""
        log("#{method.to_s.upcase} #{path}#{query}#{" body=#{body.to_json}" if body}")

        response = perform do
          connection.public_send(method) do |req|
            req.url(path, params || {})
            req.body = body.to_json if body
          end
        end
        log("-> HTTP #{response.status}")
        parse(response)
      end

      def build_connection
        Faraday.new(url: API_URL) do |f|
          f.headers["Authorization"] = "Bearer #{@token}"
          f.headers["Content-Type"] = "application/json"
          f.adapter Faraday.default_adapter
        end
      end

      def parse(response)
        data = begin
          JSON.parse(response.body)
        rescue JSON::ParserError
          raise ProviderError, "Cloudflare API returned an unparseable response (HTTP #{response.status})"
        end

        return data if response.success? && data["success"]

        messages = (data["errors"] || []).map { |e| e["message"] }.join(", ")
        raise ProviderError, "Cloudflare API error: #{messages.empty? ? response.status : messages}"
      end
    end
  end
end
