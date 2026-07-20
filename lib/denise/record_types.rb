# frozen_string_literal: true

require "ipaddr"

module Denise
  # Helpers for resolving a DNS record's type when the CLI's --type is
  # omitted: A/AAAA can be inferred from an IPv4/IPv6 --value (add-record),
  # and remove-record can fall back to whichever type the local config
  # already has for a name, as long as that's unambiguous.
  module RecordTypes
    module_function

    def infer(value)
      addr = IPAddr.new(value)
      addr.ipv4? ? "A" : "AAAA"
    rescue IPAddr::Error
      raise RecordTypeRequiredError, value
    end

    def resolve(records, name)
      matches = records.select { |r| r["name"] == name }
      case matches.size
      when 1
        matches.first["type"]
      when 0
        raise UnknownRecordError, name
      else
        raise AmbiguousRecordTypeError.new(name, matches.map { |r| r["type"] })
      end
    end
  end
end
