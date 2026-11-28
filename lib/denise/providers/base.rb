# frozen_string_literal: true

require "faraday"

module Denise
  module Providers
    # Shared interface every provider client implements. Subclasses override
    # the four record/zone methods and `build_connection`; specs inject a
    # `connection:` (typically a Faraday test-adapter double) to avoid real HTTP.
    class Base
      def initialize(token:, connection: nil)
        @token = token
        @connection = connection
      end

      def create_record(zone:, name:, type:, value:, ttl: nil)
        raise NotImplementedError, "#{self.class} must implement #create_record"
      end

      def delete_record(zone:, name:, type:)
        raise NotImplementedError, "#{self.class} must implement #delete_record"
      end

      # update_record(zone:, name:, type:, value:, old_value: nil, ttl: nil, proxied: nil)
      #
      # Changes an existing record in place, keeping whatever isn't passed
      # (nil ttl/proxied = unchanged). old_value picks one record when a name
      # has several of `type`. Only providers with an update API override
      # this: emulating it with delete + create would leave the name missing
      # in between, which is the reason the command exists.
      def update_record(**)
        raise UnsupportedOperationError,
              "#{provider_label} has no in-place record update; use remove-record and add-record"
      end

      # Whether create_record/update_record accept `proxied:` (Cloudflare's
      # orange cloud). The CLI refuses --proxied for providers without it.
      def supports_proxied?
        false
      end

      def list_records(zone:)
        raise NotImplementedError, "#{self.class} must implement #list_records"
      end

      # Every zone this token/account can manage, as bare names (no trailing
      # dot). Used to import/refresh a source's zones from the live API.
      def list_zones
        raise NotImplementedError, "#{self.class} must implement #list_zones"
      end

      private

      def provider_label
        self.class.name.split("::").last
      end

      def connection
        @connection ||= build_connection
      end

      def build_connection
        raise NotImplementedError, "#{self.class} must implement #build_connection"
      end

      # One JSON-API call (Cloudflare, DreamHost): logs method/path/query/body
      # and the status - never headers, which is where the Bearer token lives -
      # and returns the raw response for the client's own #parse.
      def send_json(method, path, params: nil, body: nil, headers: {})
        query = params ? "?#{params.map { |k, v| "#{k}=#{v}" }.join('&')}" : ""
        log("#{method.to_s.upcase} #{path}#{query}#{" body=#{body.to_json}" if body}")

        response = perform do
          connection.public_send(method) do |req|
            req.url(path, params || {})
            req.headers.update(headers)
            req.body = body.to_json if body
          end
        end
        log("-> HTTP #{response.status}")
        response
      end

      # Runs one HTTP call, turning Faraday's network-level failures (refused
      # connection, DNS, timeout, TLS) into ProviderError, so the CLI reports
      # `denise: ...` instead of crashing with a backtrace. The message is
      # scrubbed of #secrets as defense in depth, in case an adapter error
      # echoes a request detail that carries one.
      def perform
        yield
      rescue Faraday::Error => e
        raise ProviderError, "request to #{connection.url_prefix.host} failed: #{redact(e.message)}"
      end

      # Every secret string this client holds; subclasses that derive more
      # than one from the token (Aws) add theirs.
      def secrets
        [@token]
      end

      def redact(text)
        secrets.compact.reject(&:empty?).reduce(text) { |t, secret| t.gsub(secret, "[REDACTED]") }
      end

      # Only called by subclasses with method/path/params/status - never with
      # headers or a token/secret. Writes to stderr, gated on Denise.verbose,
      # so `-v` never touches what a command prints to stdout.
      def log(message)
        return unless Denise.verbose

        warn "[#{self.class.name.split('::').last}] #{message}"
      end
    end
  end
end
