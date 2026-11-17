# frozen_string_literal: true

require "tomlib"
require "fileutils"

module Denise
  # Reads and writes ~/.config/denise-cli/config.toml: sources (provider
  # instances, each with a unique alias and an API token) and the zones
  # under each source. A token lives in the OS credential store
  # (Denise::TokenVault, named by the source's `token_store`) whenever one is
  # usable, else encrypted into `token_encrypted` (Denise::Crypto) as a
  # fallback. Records are never stored here - add-record/
  # remove-record/list-records/search all query the live provider API
  # instead (see Denise::CLI, Denise::Search).
  class Config
    SKELETON_COMMENT = "# DeNiSe CLI configuration - see `denise help add-provider` to get started.\n\n"

    # Default cap on records.log entries (Denise::RecordLog), overridable by
    # hand-editing `log_max_records` into config.toml.
    DEFAULT_LOG_MAX_RECORDS = 10_000

    attr_reader :path

    # `vault:` is a Denise::TokenVault backend, nil for none, or :detect to
    # find this platform's lazily (see #vault).
    def initialize(path: Paths.config_file, crypto: Crypto.new, vault: :detect)
      @path = path
      @crypto = crypto
      @vault = vault unless vault == :detect
      @data = load
      migrate_tokens!
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
      src = source(alias_name)
      return @crypto.decrypt(src["token_encrypted"]) if src["token_encrypted"]

      store = src["token_store"] or raise MissingTokenError, alias_name
      raise TokenStoreUnavailableError.new(alias_name, store) unless vault&.name == store

      vault.fetch(alias_name) || raise(MissingTokenError, alias_name)
    end

    # Where a source's token is kept, for display.
    def token_location(alias_name)
      store = source(alias_name)["token_store"]
      store ? "the #{TokenVault.label_for(store)}" : "config.toml (encrypted)"
    end

    def add_source(provider:, token:, alias_name: nil, default: false)
      raise UnknownProviderError, provider unless Providers.known?(provider)

      check_token!(token)
      resolved_alias = alias_name ? claim_alias(alias_name) : auto_alias(provider)

      sources[resolved_alias] = { "provider" => provider, "zones" => [] }
      store_token(resolved_alias, token)
      @data["default_source"] = resolved_alias if default || @data["default_source"].nil?
      save
      resolved_alias
    end

    # Replaces a source's API token (e.g. after rotating it at the provider),
    # leaving its provider type and zones untouched.
    def update_token(alias_name, token)
      source(alias_name)
      check_token!(token)
      store_token(alias_name, token)
      save
    end

    def remove_source(alias_name)
      raise UnknownSourceError, alias_name unless sources.key?(alias_name)

      forget_vault_token(alias_name, sources.delete(alias_name)["token_store"])
      @data["default_source"] = sources.keys.first if @data["default_source"] == alias_name
      save
    end

    # The OS credential store (a Denise::TokenVault backend, or nil if none
    # is usable), detected on first use rather than at load - so commands
    # that never touch a token never spawn `security`/`secret-tool`.
    def vault
      return @vault if defined?(@vault)

      @vault = TokenVault.detect(config_dir: File.dirname(@path))
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

    def check_token!(token)
      raise BlankTokenError if token.to_s.strip.empty?
    end

    # Puts a source's token in the OS credential store if one is usable,
    # else encrypts it into config.toml. Doesn't save; callers do.
    def store_token(alias_name, token)
      src = source(alias_name)
      return if vault && move_to_vault(alias_name, token)

      src["token_encrypted"] = @crypto.encrypt(token)
      src.delete("token_store")
    end

    # Stores the token in the vault and reads it back before dropping
    # `token_encrypted`, so a token is never removed from config.toml unless
    # it's verifiably retrievable from the vault. Returns whether it moved;
    # on failure the source is left exactly as it was. `quiet:` is for the
    # opportunistic retry on every load (see #migrate_token) - a keyring
    # that's installed but locked (SSH, headless) would otherwise warn on
    # every single command.
    def move_to_vault(alias_name, token, quiet: false)
      vault.store(alias_name, token)
      raise VaultError, "#{vault.label} returned a different token than was stored" if vault.fetch(alias_name) != token

      src = source(alias_name)
      src.delete("token_encrypted")
      src["token_store"] = vault.name
      true
    rescue VaultError => e
      warn "denise: #{e.message}; keeping the token for '#{alias_name}' encrypted in config.toml" unless quiet
      false
    end

    def forget_vault_token(alias_name, store)
      return unless store
      return vault.delete(alias_name) if vault&.name == store

      warn "denise: #{TokenVault.label_for(store)} isn't available; the token for '#{alias_name}' was left in it"
    rescue VaultError => e
      warn "denise: #{e.message}; the token for '#{alias_name}' may have been left in the #{vault.label}"
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

    # Runs on every load, rewriting config.toml immediately if anything
    # changed. A hand-edited plaintext `token` (the user has no way to
    # produce ciphertext or a keychain entry themselves) is stored right away
    # and dropped, so it's never written back to disk in plaintext - and
    # always wins over whatever was stored before, which doubles as manual
    # rotation. An existing `token_encrypted` is moved into the OS credential
    # store as soon as one is usable.
    def migrate_tokens!
      save if sources.keys.map { |alias_name| migrate_token(alias_name) }.any?
    end

    def migrate_token(alias_name)
      src = source(alias_name)
      if src.key?("token")
        store_token(alias_name, src.delete("token"))
        true
      elsif src["token_encrypted"] && vault
        moved = move_to_vault(alias_name, @crypto.decrypt(src["token_encrypted"]), quiet: !Denise.verbose)
        warn "denise: moved the token for '#{alias_name}' into the #{vault.label}" if moved
        moved
      else
        false
      end
    rescue OpenSSL::Cipher::CipherError, ArgumentError
      warn "denise: couldn't decrypt the token for '#{alias_name}'; run `denise update-token #{alias_name}`"
      false
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
