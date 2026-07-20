# frozen_string_literal: true

require "thor"
require "io/console"

module Denise
  class CLI < Thor
    def self.exit_on_failure?
      true
    end

    class_option :provider, aliases: "-p", desc: "Source alias to operate on (defaults to the default provider)"

    def initialize(*args)
      super
      @config = Config.new
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
      print_table([["--completions [bash|zsh]", "Print a shell completion script (defaults to $SHELL)"]], indent: 2)
    end
    # rubocop:enable Style/OptionalBooleanParameter

    desc "add-provider PROVIDER", "Add a new provider source (cloudflare, dreamhost, aws)"
    method_option :alias, desc: "Alias for this source (defaults to the provider's default alias)"
    method_option :token,
                  desc: "API token, prompted securely if omitted " \
                        "(aws: ACCESS_KEY_ID:SECRET_ACCESS_KEY)"
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
      say "Added #{provider} as '#{alias_name}'#{default_note}."
    rescue Error => e
      error_exit(e)
    end

    desc "list-providers", "List configured provider sources"
    def list_providers
      if @config.sources.empty?
        say "No providers configured. Use `denise add-provider` to add one."
        return
      end

      rows = @config.sources.map do |alias_name, src|
        [alias_name, src["provider"], (alias_name == @config.default_source_alias ? "*" : "")]
      end
      print_table([%w[ALIAS PROVIDER DEFAULT], *rows])
    end

    desc "remove-provider ALIAS", "Remove a provider source (alias must be given explicitly)"
    method_option :yes, aliases: "-y", type: :boolean, default: false, desc: "Skip the confirmation prompt"
    def remove_provider(alias_name)
      @config.source(alias_name)

      unless options[:yes] || yes?("Remove provider '#{alias_name}' and all its zones/entries? (y/N)")
        say "Aborted."
        return
      end

      @config.remove_source(alias_name)
      say "Removed '#{alias_name}'."
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
      print_table([%w[ALIAS ZONE], *rows])
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

    desc "add-entry NAME", "Add a DNS entry to a zone"
    method_option :zone, aliases: "-z", required: true, desc: "Zone to add the entry to"
    method_option :type, required: true, desc: "Record type (A, AAAA, CNAME, TXT, MX, ...)"
    method_option :value, required: true, desc: "Record value"
    method_option :ttl, type: :numeric, desc: "Time to live in seconds"
    def add_entry(name)
      zone, type, value, ttl = options.values_at("zone", "type", "value", "ttl")
      alias_name = resolve_provider_alias(zone: zone)

      provider_client(alias_name).create_record(zone: zone, name: name, type: type, value: value, ttl: ttl)
      @config.add_entry(zone, provider_alias: alias_name, name: name, type: type, value: value, ttl: ttl)
      say "Added #{type} entry '#{name}' to zone '#{zone}' (#{alias_name})."
    rescue Error => e
      error_exit(e)
    end

    desc "list-entries", "List DNS entries denise has added to a zone (from local config, not a live query)"
    method_option :zone, aliases: "-z", required: true, desc: "Zone to list entries for"
    def list_entries
      alias_name = resolve_provider_alias(zone: options[:zone])
      rows = @config.list_entries(options[:zone], provider_alias: alias_name)
                    .map { |e| [e["name"], e["type"], e["value"], e["ttl"]] }
      if rows.empty?
        say "No entries configured for '#{options[:zone]}'."
        return
      end
      print_table([%w[NAME TYPE VALUE TTL], *rows])
    rescue Error => e
      error_exit(e)
    end

    desc "remove-entry NAME", "Remove a DNS entry from a zone"
    method_option :zone, aliases: "-z", required: true, desc: "Zone the entry belongs to"
    method_option :type, required: true, desc: "Record type of the entry to remove"
    def remove_entry(name)
      zone, type = options.values_at("zone", "type")
      alias_name = resolve_provider_alias(zone: zone)

      provider_client(alias_name).delete_record(zone: zone, name: name, type: type)
      @config.remove_entry(zone, provider_alias: alias_name, name: name, type: type)
      say "Removed #{type} entry '#{name}' from zone '#{zone}' (#{alias_name})."
    rescue Error => e
      error_exit(e)
    end

    desc "version", "Print the denise version"
    def version
      say VERSION
    end

    private

    # Provider resolution order: -p/--provider, then inferred from the zone
    # that owns it (-z/--zone), then the configured default provider.
    def resolve_provider_alias(zone: nil)
      return options[:provider] if options[:provider]

      if zone
        matches = @config.sources_for_zone(zone)
        case matches.size
        when 1
          return matches.first
        when 0
          # no source owns this zone yet; fall through to the default
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

    def prompt_token(provider)
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
