# frozen_string_literal: true

require "tomlib"
require "fileutils"

module Denise
  # Reads and writes ~/.config/denise-cli/config.toml: sources (provider
  # instances, each with a unique alias and an encrypted API token) and the
  # zones under each source. Records are never stored here - add-record/
  # remove-record/list-records/search all query the live provider API
  # instead (see Denise::CLI, Denise::Search).
  class Config
    SKELETON_COMMENT = "# DeNiSe CLI configuration - see `denise help add-provider` to get started.\n\n"

    # Default cap on records.log entries (Denise::RecordLog), overridable by
    # hand-editing `log_max_records` into config.toml.
    DEFAULT_LOG_MAX_RECORDS = 10_000

    attr_reader :path

    def initialize(path: Paths.config_file, crypto: Crypto.new)
      @path = path
      @crypto = crypto
      @data = load
      encrypt_plaintext_tokens!
      migrate_legacy_zones!
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

    # Max entries kept in records.log before the oldest are shifted out
    # (Denise::RecordLog). Hand-edit `log_max_records` in config.toml to
    # override; there's no dedicated command for it, same as manual token
    # rotation.
    def log_max_records
      @data["log_max_records"] || DEFAULT_LOG_MAX_RECORDS
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
      redacted["log_max_records"] = log_max_records
      redacted["sources"] = sources.transform_values { |src| src.except("token_encrypted") }
      Tomlib.dump(redacted)
    end

    # -- zones ------------------------------------------------------------

    def add_zone(zone_name, provider_alias:)
      zones = (source(provider_alias)["zones"] ||= [])
      raise ZoneConflictError, zone_name if zones.include?(zone_name)

      zones << zone_name
      save
    end

    def remove_zone(zone_name, provider_alias:)
      zones = source(provider_alias)["zones"] ||= []
      raise UnknownZoneError, zone_name unless zones.include?(zone_name)

      zones.delete(zone_name)
      save
    end

    def list_zones(provider_alias: nil)
      aliases = provider_alias ? [provider_alias] : sources.keys
      aliases.flat_map { |a| (source(a)["zones"] || []).map { |z| { alias: a, name: z } } }
    end

    # Whether this source has the given zone tracked locally - add-record/
    # remove-record/list-records check this before querying the live API, so
    # a typoed -z fails fast with UnknownZoneError instead of hitting the
    # provider blind.
    def zone?(zone_name, provider_alias:)
      (source(provider_alias)["zones"] || []).include?(zone_name)
    end

    # Aliases of every source that has a zone with this name.
    def sources_for_zone(zone_name)
      sources.select { |_a, src| (src["zones"] || []).include?(zone_name) }.keys
    end

    # Reconciles a source's zones against a live list of zone names from its
    # provider: adds zones that are new and drops zones that no longer exist
    # there. Zones present in both are left untouched. Returns the
    # added/removed zone names for reporting.
    def sync_zones(provider_alias, zone_names)
      zones = (source(provider_alias)["zones"] ||= [])

      added = zone_names - zones
      removed = zones - zone_names

      zones.reject! { |z| removed.include?(z) }
      zones.concat(added)

      save
      { added: added, removed: removed }
    end

    private

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

    # Older denise versions stored each zone as a {"name" => ..., "records"
    # => [...]} table (records used to live in config.toml - see the class
    # comment). Flatten any such entries down to bare zone-name strings on
    # load, dropping the now-unused records, so upgrading doesn't require a
    # manual config.toml edit - and rewrite immediately so this only ever
    # runs once per source.
    def migrate_legacy_zones!
      migrated = false
      sources.each_value do |src|
        zones = src["zones"]
        next unless zones&.any?(Hash)

        src["zones"] = zones.map { |z| z.is_a?(Hash) ? z["name"] : z }
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
