# frozen_string_literal: true

require "thor"
require "io/console"

module Denise
  class CLI < Thor
    def self.exit_on_failure?
      true
    end

    extend CLIDispatch

    class_option :provider, aliases: "-p", desc: "Source alias to operate on (defaults to the default provider)"
    class_option :verbose, aliases: "-v", type: :boolean, default: false,
                           desc: "Print HTTP requests/responses to providers (never includes tokens or secrets)"

    TOKEN_OPTION_DESC = "API token (aws: ACCESS_KEY_ID:SECRET_ACCESS_KEY). Avoid: it's left in shell history " \
                        "and visible in `ps`. Omit it to be prompted securely, or pipe the token on stdin"

    def initialize(*args)
      super
      Denise.verbose = options[:verbose]
      @config = Config.new
      @record_log = RecordLog.new(config: @config)
    end

    desc "help [COMMAND]", "Describe available commands or one specific command"
    # rubocop:disable Style/OptionalBooleanParameter -- must match Thor's own help(command, subcommand)
    # signature exactly; Thor calls it positionally both via `super` and its own internal dispatch.
    def help(command = nil, subcommand = false)
      if command.nil?
        say "DeNiSe CLI - a hobbyist DNS manager for Cloudflare, DreamHost, and AWS Route 53."
        say
      end

      super

      return if command

      say "Global flags:"
      Table.print(
        [
          ["--completions [bash|zsh]", "Print a shell completion script (defaults to $SHELL)"],
          ["-h, --help", "Show this help (same as `denise help`)"]
        ], indent: 2
      )
    end
    # rubocop:enable Style/OptionalBooleanParameter

    desc "config", "Display the configuration, without secrets (creates a skeleton file if none exists)"
    def config
      if @config.ensure_file!
        say "No config file found; created a skeleton at #{@config.path}."
        say
      end
      puts @config.to_toml_without_secrets
    end

    desc "add-provider PROVIDER", "Add a new provider source (cloudflare, dreamhost, aws) and import its zones"
    method_option :alias, desc: "Alias for this source (defaults to the provider's default alias)"
    method_option :token, desc: TOKEN_OPTION_DESC
    method_option :default, type: :boolean, default: false, desc: "Make this the default provider"
    def add_provider(provider)
      token = options[:token] || prompt_token(provider)
      alias_name = @config.add_source(
        provider: provider,
        token: token,
        alias_name: options[:alias],
        default: options[:default]
      )
      default_note = @config.default_source_alias == alias_name ? " (default)" : ""
      say "Added #{provider} as '#{alias_name}'#{default_note}; token stored in #{@config.token_location(alias_name)}."

      begin
        sync_zones_for(alias_name)
      rescue Error => e
        warn "denise: could not import zones for '#{alias_name}' (#{e.message}); " \
             "try `denise refresh-zones -p #{alias_name}` later."
      end
    rescue Error => e
      error_exit(e)
    end

    map "list-sources" => "list-providers"
    desc "list-providers", "List configured provider sources"
    def list_providers
      if @config.sources.empty?
        say "No providers configured. Use `denise add-provider` to add one."
        return
      end

      rows = @config.sources.map do |alias_name, src|
        [alias_name, src["provider"], (alias_name == @config.default_source_alias ? "*" : "")]
      end
      Table.print([%w[ALIAS PROVIDER DEFAULT], *rows])
    end

    desc "remove-provider ALIAS", "Remove a provider source (alias must be given explicitly)"
    method_option :yes, aliases: "-y", type: :boolean, default: false, desc: "Skip the confirmation prompt"
    def remove_provider(alias_name)
      @config.source(alias_name)

      unless options[:yes] || yes?("Remove provider '#{alias_name}' and all its zones/records? (y/N)")
        say "Aborted."
        return
      end

      @config.remove_source(alias_name)
      say "Removed '#{alias_name}'."
    rescue Error => e
      error_exit(e)
    end

    desc "update-token ALIAS", "Replace a provider source's API token (alias must be given explicitly)"
    method_option :token, desc: TOKEN_OPTION_DESC
    def update_token(alias_name)
      provider = @config.source(alias_name)["provider"]
      @config.update_token(alias_name, options[:token] || prompt_token(provider))
      say "Updated token for '#{alias_name}', stored in #{@config.token_location(alias_name)}."
    rescue Error => e
      error_exit(e)
    end

    desc "set-default-provider ALIAS", "Set the default provider source"
    def set_default_provider(alias_name)
      @config.set_default_source(alias_name)
      say "Default provider set to '#{alias_name}'."
    rescue Error => e
      error_exit(e)
    end

    desc "add-zone ZONE", "Add a zone to a provider source"
    def add_zone(zone)
      alias_name = resolve_provider_alias
      @config.add_zone(zone, provider_alias: alias_name)
      say "Added zone '#{zone}' to '#{alias_name}'."
    rescue Error => e
      error_exit(e)
    end

    desc "list-zones", "List zones (optionally filtered with -p/--provider)"
    def list_zones
      rows = @config.list_zones(provider_alias: options[:provider]).map { |z| [z[:alias], z[:name]] }
      if rows.empty?
        say "No zones configured."
        return
      end
      Table.print([%w[ALIAS ZONE], *rows])
    rescue Error => e
      error_exit(e)
    end

    desc "remove-zone ZONE", "Remove a zone from a provider source"
    def remove_zone(zone)
      alias_name = resolve_provider_alias
      @config.remove_zone(zone, provider_alias: alias_name)
      say "Removed zone '#{zone}' from '#{alias_name}'."
    rescue Error => e
      error_exit(e)
    end

    desc "refresh-zones", "Refresh zones from the live API for -p/--provider, or every source if omitted"
    def refresh_zones
      aliases = options[:provider] ? [options[:provider]] : @config.sources.keys
      if aliases.empty?
        say "No providers configured."
        return
      end
      # Two passes on purpose: validate every alias exists before doing any
      # work, so an invalid -p aborts cleanly instead of syncing some
      # sources before failing partway through.
      aliases.each { |a| @config.source(a) }

      # rubocop:disable Style/CombinableLoops
      aliases.each do |alias_name|
        sync_zones_for(alias_name)
      rescue Error => e
        warn "denise: #{alias_name}: #{e.message}"
      end
      # rubocop:enable Style/CombinableLoops
    rescue Error => e
      error_exit(e)
    end

    desc "add-record NAME", "Add a DNS record to a zone"
    method_option :zone, aliases: "-z", required: true, desc: "Zone to add the record to"
    method_option :type,
                  desc: "Record type (A, AAAA, CNAME, TXT, MX, ...); if omitted, inferred as A/AAAA " \
                        "from --value when it's an IPv4/IPv6 address"
    method_option :value, required: true, desc: "Record value"
    method_option :ttl, type: :numeric, desc: "Time to live in seconds"
    def add_record(name)
      zone, value, ttl = options.values_at("zone", "value", "ttl")
      type = options[:type] || RecordTypes.infer(value)
      alias_name = resolve_provider_alias(zone: zone)

      provider_client(alias_name).create_record(zone: zone, name: name, type: type, value: value, ttl: ttl)
      @record_log.add(alias_name: alias_name, action: "add", zone: zone,
                      record: { "name" => name, "type" => type, "value" => value, "ttl" => ttl })
      say "Added #{type} record '#{name}' to zone '#{zone}' (#{alias_name})."
    rescue Error => e
      error_exit(e)
    end

    desc "list-records", "List DNS records in a zone (queries the provider live)"
    method_option :zone, aliases: "-z", required: true, desc: "Zone to list records for"
    def list_records
      zone = options[:zone]
      alias_name = resolve_provider_alias(zone: zone)

      records = provider_client(alias_name).list_records(zone: zone)
      rows = records.map { |r| [r["name"], r["type"], r["value"], r["ttl"]] }
      if rows.empty?
        say "No records found for '#{zone}'."
        return
      end
      Table.print([%w[NAME TYPE VALUE TTL], *rows])
    rescue Error => e
      error_exit(e)
    end

    desc "remove-record NAME", "Remove a DNS record from a zone"
    method_option :zone, aliases: "-z", required: true, desc: "Zone the record belongs to"
    method_option :type, desc: "Record type of the record to remove; required only if the name is ambiguous"
    def remove_record(name)
      zone = options[:zone]
      alias_name = resolve_provider_alias(zone: zone)
      client = provider_client(alias_name)
      record = RecordTypes.find(client.list_records(zone: zone), name, options[:type])

      client.delete_record(zone: zone, name: name, type: record["type"])
      @record_log.add(alias_name: alias_name, action: "remove", zone: zone, record: record)
      say "Removed #{record['type']} record '#{name}' from zone '#{zone}' (#{alias_name})."
    rescue Error => e
      error_exit(e)
    end

    desc "search QUERY", "Search zone names, record names, and record values (queries providers live for names/values)"
    method_option :limit, desc: "Comma-separated categories to search: zones,names,values (default: all)"
    def search(query)
      aliases = Search.provider_aliases(@config, options[:provider]) { resolve_provider_alias }
      rows = Search.rows(@config, query, aliases, Search.categories(options[:limit])) { |a| provider_client(a) }
      return say "No matches for '#{query}'." if rows.empty?

      Table.print([%w[PROVIDER ZONE MATCH NAME TYPE VALUE TTL], *rows])
    rescue Error => e
      error_exit(e)
    end

    desc "version", "Print the denise version"
    def version
      say VERSION
    end

    private

    # Provider resolution order: -p/--provider, then inferred from the zone
    # that owns it (-z/--zone), then the configured default provider. A
    # given zone must already be tracked under the resolved alias (records
    # are never stored locally, so there's no other way to catch a typoed
    # -z before it reaches the live API) - raises UnknownZoneError otherwise.
    def resolve_provider_alias(zone: nil)
      if options[:provider]
        raise UnknownZoneError, zone if zone && !@config.zone?(zone, provider_alias: options[:provider])

        return options[:provider]
      end

      if zone
        matches = @config.sources_for_zone(zone)
        case matches.size
        when 1
          return matches.first
        when 0
          raise UnknownZoneError, zone
        else
          raise AmbiguousZoneError.new(zone, matches)
        end
      end

      @config.default_source_alias || raise(NoProviderError)
    end

    def provider_client(alias_name)
      src = @config.source(alias_name)
      Providers.client_for(src["provider"], token: @config.token_for(alias_name))
    end

    def sync_zones_for(alias_name)
      ZoneSync.call(@config, alias_name, provider_client(alias_name)).each { |line| say line }
    end

    # Gets a token without it ever appearing in argv (shell history, `ps`):
    # a no-echo prompt on a terminal, or the first line of piped stdin
    # (e.g. `pass show cf | denise update-token cf`) otherwise.
    def prompt_token(provider)
      return $stdin.gets&.chomp unless $stdin.tty?

      label = provider == "aws" ? "AWS token (ACCESS_KEY_ID:SECRET_ACCESS_KEY)" : "API token"
      print "#{label}: "
      token = $stdin.noecho(&:gets)&.chomp
      puts
      token
    end

    def error_exit(err)
      warn "denise: #{err.message}"
      exit 1
    end
  end
end
