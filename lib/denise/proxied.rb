# frozen_string_literal: true

module Denise
  # The CLI side of Cloudflare's proxy flag (orange cloud): turning
  # --proxied/--no-proxied into provider kwargs, and showing a record's
  # setting. Providers without a proxy never report the "proxied" key, so
  # their output is unchanged.
  module Proxied
    module_function

    # { proxied: true/false } when the flag was given, else {} so the provider
    # leaves the setting alone. Refused for providers without a proxy, rather
    # than silently ignored.
    def option(client, flag)
      return {} if flag.nil?
      raise UnsupportedOperationError, "--proxied/--no-proxied is Cloudflare only" unless client.supports_proxied?

      { proxied: flag }
    end

    # list-records cell: blank for providers without the flag, so Table drops
    # the column.
    def cell(record)
      return nil unless record.key?("proxied")

      record["proxied"] ? "yes" : "no"
    end

    def note(record)
      return "" unless record.key?("proxied")

      record["proxied"] ? " (proxied)" : " (DNS only)"
    end
  end
end
