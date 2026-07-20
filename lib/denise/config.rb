# frozen_string_literal: true

require "tomlib"
require "fileutils"

module Denise
  # Reads and writes ~/.config/denise-cli/config.toml: sources (provider
  # instances, each with a unique alias and an encrypted API token), the
  # zones under each source, and the DNS records under each zone.
  class Config
    SKELETON_COMMENT = "# DeNiSe CLI configuration - see `denise help add-provider` to get started.\n\n"

    attr_reader :path

    def initialize(path: Paths.config_file, crypto: Crypto.new)
      @path = path
      @crypto = crypto
      @data = load
      encrypt_plaintext_tokens!
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
      encrypted = source(alias_name)["token_encrypted"]
      raise MissingTokenError, alias_name unless encrypted

      @crypto.decrypt(encrypted)
    end

    def add_source(provider:, token:, alias_name: nil, default: false)
      raise UnknownProviderError, provider unless Providers.known?(provider)

      resolved_alias = alias_name ? claim_alias(alias_name) : auto_alias(provider)

      sources[resolved_alias] = {
        "provider" => provider,
        "token_encrypted" => @crypto.encrypt(token),
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

    # Writes a skeleton config.toml if one doesn't exist yet. Returns
    # whether it created one, so callers can tell the user what happened.
    def ensure_file!
      return false if File.exist?(@path)

      FileUtils.mkdir_p(File.dirname(@path))
      File.write(@path, "#{SKELETON_COMMENT}#{Tomlib.dump(@data)}")
      true
    end

    # The full config as TOML, with every source's token_encrypted omitted.
    def to_toml_without_secrets
      redacted = {}
      redacted["default_source"] = @data["default_source"] if @data["default_source"]
      redacted["sources"] = sources.transform_values { |src| src.except("token_encrypted") }
      Tomlib.dump(redacted)
    end

    # -- zones ------------------------------------------------------------

    def add_zone(zone_name, provider_alias:)
      src = source(provider_alias)
      zones = (src["zones"] ||= [])
      raise ZoneConflictError, zone_name if zones.any? { |z| z["name"] == zone_name }

      zones << { "name" => zone_name, "records" => [] }
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

    # Reconciles a source's zones against a live list of zone names from its
    # provider: adds zones that are new (with an empty records list) and
    # drops zones that no longer exist there (along with their locally
    # tracked records). Zones present in both are left untouched, so their
    # records survive. Returns the added/removed zone names for reporting.
    def sync_zones(provider_alias, zone_names)
      zones = (source(provider_alias)["zones"] ||= [])
      existing_names = zones.map { |z| z["name"] }

      added = zone_names - existing_names
      removed = existing_names - zone_names

      zones.reject! { |z| removed.include?(z["name"]) }
      added.each { |name| zones << { "name" => name, "records" => [] } }

      save
      { added: added, removed: removed }
    end

    # -- records ----------------------------------------------------------

    def add_record(zone_name, provider_alias:, name:, type:, value:, ttl: nil)
      zone = find_zone(provider_alias, zone_name)
      record = { "name" => name, "type" => type, "value" => value }
      record["ttl"] = ttl if ttl
      (zone["records"] ||= []) << record
      save
    end

    def remove_record(zone_name, provider_alias:, name:, type:)
      records = find_zone(provider_alias, zone_name)["records"] ||= []
      record = records.find { |r| r["name"] == name && r["type"] == type }
      raise UnknownRecordError, name unless record

      records.delete(record)
      save
    end

    def list_records(zone_name, provider_alias:)
      find_zone(provider_alias, zone_name)["records"] || []
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

    # A hand-edited config.toml may set a plaintext `token` (the user has no
    # way to produce the encrypted form themselves). Encrypt it into
    # `token_encrypted` and drop the plaintext, so it's never written back
    # to disk unencrypted. Also covers manual token rotation: a freshly
    # hand-edited `token` always wins over a stale `token_encrypted`.
    def encrypt_plaintext_tokens!
      migrated = false
      sources.each_value do |src|
        next unless src.key?("token")

        src["token_encrypted"] = @crypto.encrypt(src.delete("token"))
        migrated = true
      end
      save if migrated
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
