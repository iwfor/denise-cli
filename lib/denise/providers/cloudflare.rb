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

      # proxied: nil leaves it to Cloudflare, which makes new records DNS-only.
      def create_record(zone:, name:, type:, value:, ttl: nil, proxied: nil)
        body = { type: type, name: name, content: value }
        body[:ttl] = ttl if ttl
        body[:proxied] = proxied unless proxied.nil?
        request(:post, "zones/#{zone_id(zone)}/dns_records", body: body)
      end

      def delete_record(zone:, name:, type:)
        record = find_record(zone, name: name, type: type)
        request(:delete, "zones/#{zone_id(zone)}/dns_records/#{record['id']}")
      end

      # PATCH sends only what changes, so the record keeps its other fields
      # (proxied, ttl, comment) - unlike delete + create, which would drop the
      # name from DNS in between and come back DNS-only.
      # changes: ttl:, proxied: - nil (or absent) means unchanged.
      def update_record(zone:, name:, type:, value:, old_value: nil, **changes)
        record = find_record(zone, name: name, type: type, value: old_value)
        body = { content: value }.merge(changes.slice(:ttl, :proxied).compact)
        normalize(request(:patch, "zones/#{zone_id(zone)}/dns_records/#{record['id']}", body: body).fetch("result"))
      end

      def list_records(zone:)
        paginate("zones/#{zone_id(zone)}/dns_records", per_page: 100).map { |r| normalize(r) }
      end

      def list_zones
        paginate("zones", per_page: 50).map { |z| z["name"] }
      end

      def supports_proxied?
        true
      end

      private

      def normalize(record)
        { "name" => record["name"], "type" => record["type"], "value" => record["content"],
          "ttl" => record["ttl"], "proxied" => record["proxied"] }
      end

      # Every page of a list endpoint (Cloudflare returns at most per_page per call).
      def paginate(path, per_page:, params: {})
        items = []
        page = 1
        loop do
          data = request(:get, path, params: params.merge(page: page, per_page: per_page))
          items.concat(data.fetch("result"))
          break if page >= (data.dig("result_info", "total_pages") || 1)

          page += 1
        end
        items
      end

      # The one record named name/type (and with content `value`, when given).
      # No match, or several without a value to pick by, is an error - never
      # a silent pick of the first.
      def find_record(zone, name:, type:, value: nil)
        matches = request(:get, "zones/#{zone_id(zone)}/dns_records",
                          params: { name: fqdn(zone, name), type: type }).fetch("result")
        matches = matches.select { |r| r["content"] == value } if value
        if matches.empty?
          with_value = value ? " with value '#{value}'" : ""
          raise ProviderError, "no #{type} record named '#{name}'#{with_value} found in zone '#{zone}'"
        end
        raise AmbiguousRecordError.new(name, type, matches.map { |r| r["content"] }) if matches.size > 1

        matches.first
      end

      # Cloudflare's name filter matches only full names; the CLI also accepts
      # names relative to the zone ("www" for www.example.com).
      def fqdn(zone, name)
        name == zone || name.end_with?(".#{zone}") ? name : "#{name}.#{zone}"
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
