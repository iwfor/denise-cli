# frozen_string_literal: true

require "faraday"
require "json"
require "securerandom"

module Denise
  module Providers
    # DreamHost's v1 REST API (the legacy `?cmd=dns-...` API was retired
    # 2026-11-22). The OpenAPI spec is the reference:
    # https://developers.dreamhost.com/spec/external/json?version=v1
    #
    # - Auth is `Authorization: Bearer <key>`; v1 keys are new (legacy keys
    #   don't work) and scoped per area - denise needs DNS read/write, plus
    #   Websites read for #list_zones.
    # - Record names are relative to the zone (`@` = apex), and there is no
    #   TTL - DreamHost manages it, so `ttl:` is accepted for interface parity
    #   and otherwise ignored.
    # - Writes are asynchronous: they return 202 with a task, which is polled
    #   (#await) until it finishes, so "Added..." and records.log only ever
    #   reflect a change DreamHost actually made.
    class Dreamhost < Base
      # Trailing slash matters - see Cloudflare::API_URL.
      API_URL = "https://api.dreamhost.com/v1/"

      # Which `fields` key carries a record's value, per writable type. MX
      # isn't writable through the API yet, and CAA/SRV/NAPTR take several
      # structured fields that a single --value doesn't map onto.
      VALUE_FIELD = {
        "A" => "ip", "AAAA" => "ip",
        "CNAME" => "content", "TXT" => "content", "NS" => "content", "PTR" => "content", "ALIAS" => "content"
      }.freeze

      TASK_TIMEOUT = 30 # seconds to wait for a write's task to finish
      TASK_POLL_INTERVAL = 1
      WEBSITES_PAGE_SIZE = 100 # the API's maximum

      def initialize(token:, connection: nil, sleeper: ->(seconds) { sleep(seconds) })
        super(token: token, connection: connection)
        @sleeper = sleeper
      end

      # rubocop:disable Lint/UnusedMethodArgument -- ttl kept for interface parity; DreamHost has no TTL
      def create_record(zone:, name:, type:, value:, ttl: nil)
        input = record_input(name, type, value)
        await(write(:post, zone, records: [input]))
      end
      # rubocop:enable Lint/UnusedMethodArgument

      def delete_record(zone:, name:, type:)
        record = find_record(zone, name, type)
        await(write(:delete, zone, record: record.slice("name", "type", "value")))
      end

      def list_records(zone:)
        request(:get, "dns/#{zone}").fetch("data").map do |r|
          { "name" => r["name"], "type" => r["type"], "value" => r["value"], "ttl" => nil }
        end
      end

      # The DNS API has no zone listing, so zones are the account's websites
      # (which include `dns_only` and `parked` domains, not just hosted ones).
      # Subdomain websites (files.example.com) are dropped when their parent
      # is listed too: DNS for them is just a view onto the parent zone's
      # records, so tracking both would duplicate every search hit.
      def list_zones
        domains = []
        loop do
          page = request(:get, "websites", params: { limit: WEBSITES_PAGE_SIZE, offset: domains.size })
          domains.concat(page.fetch("data").map { |w| w["domain"] })
          break if page["data"].empty? || domains.size >= page.dig("meta", "total").to_i
        end
        domains.reject { |d| domains.any? { |parent| d.end_with?(".#{parent}") } }
      end

      private

      def record_input(name, type, value)
        type = type.to_s.upcase
        field = VALUE_FIELD[type]
        unless field
          raise ProviderError, "denise can't create #{type} records through DreamHost's API " \
                               "(supported: #{VALUE_FIELD.keys.join(', ')})"
        end

        { name: name.to_s.empty? ? "@" : name, type: type, fields: { field => value } }
      end

      # The raw record from the live list, whose `value` is the canonical one
      # DreamHost requires to identify it for update/delete.
      def find_record(zone, name, type)
        matches = request(:get, "dns/#{zone}").fetch("data").select { |r| r["name"] == name && r["type"] == type }
        raise ProviderError, "no #{type} record named '#{name}' found in zone '#{zone}'" if matches.empty?
        if matches.size > 1
          raise ProviderError, "record '#{name}' has #{matches.size} #{type} records " \
                               "(#{matches.map { |r| r['value'] }.join(', ')}); remove the extras in DreamHost's panel"
        end

        record = matches.first
        if record["isProtected"]
          raise ProviderError, "#{type} record '#{name}' is managed by DreamHost (#{record['managedBy']}) " \
                               "and can't be changed through the API"
        end
        record
      end

      # The Idempotency-Key makes a retried write safe; denise doesn't retry
      # yet, but the key costs nothing and DreamHost recommends it.
      def write(method, zone, body)
        request(method, "dns/#{zone}", body: body, headers: { "Idempotency-Key" => SecureRandom.uuid })
      end

      def await(task)
        polls = TASK_TIMEOUT / TASK_POLL_INTERVAL
        while task["status"] == "scheduled" && polls.positive?
          @sleeper.call(TASK_POLL_INTERVAL)
          polls -= 1
          task = request(:get, "tasks/#{task['taskId']}")
        end
        return task if task["status"] == "success"

        if task["status"] == "scheduled"
          raise ProviderError, "DreamHost task #{task['taskId']} is still pending after #{TASK_TIMEOUT}s; " \
                               "check list-records later to see whether it took effect"
        end
        raise ProviderError, "DreamHost task #{task['taskId']} ended with status '#{task['status']}'"
      end

      def request(method, path, params: nil, body: nil, headers: {})
        parse(send_json(method, path, params: params, body: body, headers: headers))
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
          JSON.parse(response.body.to_s)
        rescue JSON::ParserError
          raise ProviderError, "DreamHost API returned an unparseable response (HTTP #{response.status})"
        end
        return data if response.success?

        raise ProviderError, "DreamHost API error: #{error_message(data, response.status)}"
      end

      # ErrorResponse: message, optional per-field details, and the
      # permissions a mis-scoped key is missing.
      def error_message(data, status)
        return "HTTP #{status}" unless data.is_a?(Hash)

        parts = [data["message"] || "HTTP #{status}"]
        parts += Array(data["details"]).map { |d| [d["field"], d["message"]].compact.join(": ") }
        missing = Array(data["requiredPermissions"])
        parts << "the API key needs permission #{missing.join(', ')}" if missing.any?
        parts.join("; ")
      end
    end
  end
end
