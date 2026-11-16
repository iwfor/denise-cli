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

      def list_records(zone:)
        raise NotImplementedError, "#{self.class} must implement #list_records"
      end

      # Every zone this token/account can manage, as bare names (no trailing
      # dot). Used to import/refresh a source's zones from the live API.
      def list_zones
        raise NotImplementedError, "#{self.class} must implement #list_zones"
      end

      private

      def connection
        @connection ||= build_connection
      end

      def build_connection
        raise NotImplementedError, "#{self.class} must implement #build_connection"
      end

      # Runs one HTTP call, turning Faraday's network-level failures (refused
      # connection, DNS, timeout, TLS) into ProviderError, so the CLI reports
      # `denise: ...` instead of crashing with a backtrace. The message is
      # scrubbed of #secrets as defense in depth: DreamHost's key travels in
      # the request URL, so an adapter error that echoed the URL would carry it.
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
