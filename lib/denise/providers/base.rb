# frozen_string_literal: true

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
    end
  end
end
