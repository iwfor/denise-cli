# frozen_string_literal: true

module Denise
  class Error < StandardError; end

  class AliasConflictError < Error
    def initialize(alias_name)
      super("alias '#{alias_name}' is already in use")
    end
  end

  class UnknownProviderError < Error
    def initialize(provider)
      super("unknown provider '#{provider}' (known: #{Providers.names.join(', ')})")
    end
  end

  class UnknownSourceError < Error
    def initialize(alias_name)
      super("no source with alias '#{alias_name}'")
    end
  end

  class ZoneConflictError < Error
    def initialize(zone_name)
      super("zone '#{zone_name}' already exists for this source")
    end
  end

  class UnknownZoneError < Error
    def initialize(zone_name)
      super("no zone named '#{zone_name}'")
    end
  end

  class UnknownRecordError < Error
    def initialize(name)
      super("no record named '#{name}'")
    end
  end

  class RecordTypeRequiredError < Error
    def initialize(value)
      super("cannot infer record type from value '#{value}'; specify --type " \
            "(only A/AAAA are inferred, from an IPv4/IPv6 --value)")
    end
  end

  class AmbiguousRecordTypeError < Error
    def initialize(name, types)
      super("record '#{name}' has multiple types (#{types.join(', ')}); specify --type")
    end
  end

  class AmbiguousZoneError < Error
    def initialize(zone_name, aliases)
      super("zone '#{zone_name}' exists under multiple sources (#{aliases.join(', ')}); specify -p/--provider")
    end
  end

  class NoProviderError < Error
    def initialize
      super("no provider specified and no default provider is set")
    end
  end

  class MissingTokenError < Error
    def initialize(alias_name)
      super("source '#{alias_name}' has no token; add `token = \"...\"` under [sources.#{alias_name}] in config.toml")
    end
  end

  # Raised by provider clients (lib/denise/providers/*) for API/network failures.
  class ProviderError < Error; end
end
