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

    # Resolves the record remove-record is about to delete from a live
    # `records` listing: an explicit `type` is validated against it
    # (UnknownRecordError if nothing matches), otherwise falls back to
    # #resolve for disambiguation. Returns the matching record hash, so the
    # caller has its value/ttl for records.log without a second lookup.
    def find(records, name, type)
      type ||= resolve(records, name)
      record = records.find { |r| r["name"] == name && r["type"] == type }
      raise UnknownRecordError, name unless record

      record
    end
  end
end
