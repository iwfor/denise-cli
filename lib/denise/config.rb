# frozen_string_literal: true

require "tomlib"
require "fileutils"

module Denise
  # Reads and writes ~/.config/denise-cli/config.toml: sources (provider
  # instances, each with a unique alias and an encrypted API token), the
  # zones under each source, and the DNS entries under each zone.
  class Config
    attr_reader :path

    def initialize(path: Paths.config_file, crypto: Crypto.new)
      @path = path
      @crypto = crypto
      @data = load
    end

    # -- sources --------------------------------------------------------

    def sources
      @data["sources"] ||= {}
    end

    def default_source_alias
      @data["default_source"]
    end

    def source(alias_name)
      sources.fetch(alias_name) { raise UnknownSourceError, alias_name }
    end

    def token_for(alias_name)
      @crypto.decrypt(source(alias_name).fetch("token"))
    end

    def add_source(provider:, token:, alias_name: nil, default: false)
      raise UnknownProviderError, provider unless Providers.known?(provider)

      resolved_alias = alias_name ? claim_alias(alias_name) : auto_alias(provider)

      sources[resolved_alias] = {
        "provider" => provider,
        "token" => @crypto.encrypt(token),
        "zones" => []
      }
      @data["default_source"] = resolved_alias if default || @data["default_source"].nil?
      save
      resolved_alias
    end

    def remove_source(alias_name)
      raise UnknownSourceError, alias_name unless sources.key?(alias_name)

      sources.delete(alias_name)
      @data["default_source"] = sources.keys.first if @data["default_source"] == alias_name
      save
    end

    def set_default_source(alias_name)
      raise UnknownSourceError, alias_name unless sources.key?(alias_name)

      @data["default_source"] = alias_name
      save
    end

    # -- zones ------------------------------------------------------------

    def add_zone(zone_name, provider_alias:)
      src = source(provider_alias)
      zones = (src["zones"] ||= [])
      raise ZoneConflictError, zone_name if zones.any? { |z| z["name"] == zone_name }

      zones << { "name" => zone_name, "entries" => [] }
      save
    end

    def remove_zone(zone_name, provider_alias:)
      zones = source(provider_alias)["zones"] ||= []
      zone = zones.find { |z| z["name"] == zone_name }
      raise UnknownZoneError, zone_name unless zone

      zones.delete(zone)
      save
    end

    def list_zones(provider_alias: nil)
      aliases = provider_alias ? [provider_alias] : sources.keys
      aliases.flat_map do |a|
        (source(a)["zones"] || []).map { |z| { alias: a, name: z["name"] } }
      end
    end

    # Aliases of every source that has a zone with this name.
    def sources_for_zone(zone_name)
      sources.select { |_a, src| (src["zones"] || []).any? { |z| z["name"] == zone_name } }.keys
    end

    # -- entries ----------------------------------------------------------

    def add_entry(zone_name, provider_alias:, name:, type:, value:, ttl: nil)
      zone = find_zone(provider_alias, zone_name)
      entry = { "name" => name, "type" => type, "value" => value }
      entry["ttl"] = ttl if ttl
      (zone["entries"] ||= []) << entry
      save
    end

    def remove_entry(zone_name, provider_alias:, name:, type:)
      entries = find_zone(provider_alias, zone_name)["entries"] ||= []
      entry = entries.find { |e| e["name"] == name && e["type"] == type }
      raise UnknownEntryError, name unless entry

      entries.delete(entry)
      save
    end

    def list_entries(zone_name, provider_alias:)
      find_zone(provider_alias, zone_name)["entries"] || []
    end

    private

    def find_zone(provider_alias, zone_name)
      zone = (source(provider_alias)["zones"] || []).find { |z| z["name"] == zone_name }
      raise UnknownZoneError, zone_name unless zone

      zone
    end

    # Explicit aliases must not collide with an existing one.
    def claim_alias(alias_name)
      raise AliasConflictError, alias_name if sources.key?(alias_name)

      alias_name
    end

    # No alias given: fall back to the provider's default alias, numbering
    # it (dh, dh2, dh3, ...) if that alias is already taken.
    def auto_alias(provider)
      base = Providers.default_alias(provider)
      return base unless sources.key?(base)

      n = 2
      n += 1 while sources.key?("#{base}#{n}")
      "#{base}#{n}"
    end

    def load
      return { "sources" => {} } unless File.exist?(@path)

      Tomlib.load(File.read(@path))
    end

    def save
      FileUtils.mkdir_p(File.dirname(@path))
      File.write(@path, Tomlib.dump(@data))
    end
  end
end
