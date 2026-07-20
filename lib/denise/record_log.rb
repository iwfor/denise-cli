# frozen_string_literal: true

require "json"
require "fileutils"
require "time"

module Denise
  # Appends one JSON line per record change to records.log in the config
  # directory: timestamp, provider type + alias, the record itself (zone,
  # name, type, value, ttl), and the action ("add"/"remove"). Capped at
  # `config.log_max_records` entries - once exceeded, the oldest line is
  # shifted out rather than rotating the whole log.
  class RecordLog
    def initialize(config:, path: Paths.records_log_file)
      @config = config
      @path = path
    end

    def add(alias_name:, action:, zone:, record:)
      entry = {
        "timestamp" => Time.now.utc.iso8601,
        "provider" => @config.source(alias_name)["provider"],
        "alias" => alias_name,
        "action" => action,
        "zone" => zone
      }.merge(record)
      append(JSON.generate(entry))
    end

    private

    def append(line)
      FileUtils.mkdir_p(File.dirname(@path))
      lines = File.exist?(@path) ? File.readlines(@path, chomp: true) : []
      lines << line
      max = @config.log_max_records
      lines.shift(lines.size - max) if lines.size > max
      File.write(@path, "#{lines.join("\n")}\n")
    end
  end
end
