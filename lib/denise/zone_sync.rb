# frozen_string_literal: true

module Denise
  # Supporting logic for add-provider/refresh-zones' shared "sync a source's
  # zones from the live API and report what changed" step, kept out of CLI
  # to stay under Metrics/ClassLength (same pattern as RecordTypes/Search).
  module ZoneSync
    module_function

    # Syncs alias_name's zones from client.list_zones and returns the report
    # lines to print: one "up to date" line if nothing changed, otherwise up
    # to two lines (added/removed).
    def call(config, alias_name, client)
      added, removed = config.sync_zones(alias_name, client.list_zones).values_at(:added, :removed)
      return ["#{alias_name}: zones up to date."] if added.empty? && removed.empty?

      [
        added.any? ? "#{alias_name}: added #{added.join(', ')}." : nil,
        removed.any? ? "#{alias_name}: removed #{removed.join(', ')}." : nil
      ].compact
    end
  end
end
