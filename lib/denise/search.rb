# frozen_string_literal: true

module Denise
  # Supporting logic for the `search` command, kept out of CLI to stay under
  # Metrics/ClassLength (same pattern as lib/denise/record_types.rb).
  #
  # Records are never stored locally (see Config), so matching record names
  # and values means querying each zone's live records - unlike zone-name
  # matching, which only needs Config#list_zones.
  module Search
    module_function

    CATEGORIES = %w[zones names values].freeze

    # Parses --limit into a category list, validated against CATEGORIES.
    def categories(limit)
      return CATEGORIES if limit.nil?

      given = limit.split(",").map(&:strip)
      unknown = given - CATEGORIES
      raise InvalidSearchLimitError.new(unknown, CATEGORIES) if unknown.any?

      given
    end

    # -p/--provider accepts the virtual alias "all" (every configured
    # source) in addition to a real alias; a real alias or the default
    # provider is resolved by the block (CLI#resolve_provider_alias).
    def provider_aliases(config, provider_option)
      return config.sources.keys if provider_option == "all"

      [yield]
    end

    # client_for resolves a provider client for an alias (CLI#provider_client),
    # used lazily - only zones actually needing a names/values match trigger
    # a live list_records call.
    def rows(config, query, aliases, categories, &client_for)
      needle = query.downcase
      aliases.flat_map { |alias_name| source_rows(config, alias_name, needle, categories, client_for) }
    end

    def source_rows(config, alias_name, needle, categories, client_for)
      config.list_zones(provider_alias: alias_name).flat_map do |zone|
        zone_rows(alias_name, zone[:name], needle, categories, client_for)
      end
    end

    def zone_rows(alias_name, zone_name, needle, categories, client_for)
      rows = []
      if categories.include?("zones") && zone_name.downcase.include?(needle)
        rows << [alias_name, zone_name, "zone", nil, nil, nil, nil]
      end
      rows.concat(record_rows(alias_name, zone_name, needle, categories, client_for)) if record_search?(categories)
      rows
    end

    def record_search?(categories)
      categories.include?("names") || categories.include?("values")
    end

    def record_rows(alias_name, zone_name, needle, categories, client_for)
      client_for.call(alias_name).list_records(zone: zone_name).filter_map do |record|
        matched = record_match(record, needle, categories)
        next if matched.empty?

        [alias_name, zone_name, matched.join(","), record["name"], record["type"], record["value"], record["ttl"]]
      end
    rescue ProviderError => e
      warn "denise: #{alias_name}/#{zone_name}: #{e.message}"
      []
    end

    def record_match(record, needle, categories)
      matched = []
      matched << "name" if categories.include?("names") && record["name"].downcase.include?(needle)
      matched << "value" if categories.include?("values") && record["value"].downcase.include?(needle)
      matched
    end
  end
end
