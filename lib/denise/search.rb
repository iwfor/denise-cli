# frozen_string_literal: true

module Denise
  # Supporting logic for the `search` command, kept out of CLI to stay under
  # Metrics/ClassLength (same pattern as lib/denise/record_types.rb).
  module Search
    module_function

    # Parses --limit into a category list, validated against
    # Config::SEARCH_CATEGORIES.
    def categories(limit)
      return Config::SEARCH_CATEGORIES if limit.nil?

      given = limit.split(",").map(&:strip)
      unknown = given - Config::SEARCH_CATEGORIES
      raise InvalidSearchLimitError.new(unknown, Config::SEARCH_CATEGORIES) if unknown.any?

      given
    end

    # -p/--provider accepts the virtual alias "all" (every configured
    # source) in addition to a real alias; a real alias or the default
    # provider is resolved by the block (CLI#resolve_provider_alias).
    def provider_aliases(config, provider_option)
      return config.sources.keys if provider_option == "all"

      [yield]
    end

    # Flattens each matching source's hits into print_table rows.
    def rows(config, query, aliases, categories)
      aliases.flat_map do |alias_name|
        config.search(query, provider_alias: alias_name, categories: categories).map do |hit|
          [alias_name, hit[:zone], hit[:match], hit[:name], hit[:type], hit[:value], hit[:ttl]]
        end
      end
    end
  end
end
