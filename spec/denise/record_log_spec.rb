# frozen_string_literal: true

require "json"

RSpec.describe Denise::RecordLog do
  let(:config) { Denise::Config.new }
  let(:path) { Denise::Paths.records_log_file }

  before { config.add_source(provider: "dreamhost", token: "t1", alias_name: "dh", default: true) }

  def entries
    File.readlines(path, chomp: true).map { |line| JSON.parse(line) }
  end

  it "creates the config dir and appends one JSON line per call, resolving the provider from the alias" do
    log = described_class.new(config: config, path: path)

    log.add(alias_name: "dh", action: "add", zone: "example.com",
            record: { "name" => "www", "type" => "A", "value" => "1.2.3.4", "ttl" => 300 })

    lines = File.readlines(path, chomp: true)
    expect(lines.size).to eq(1)

    entry = JSON.parse(lines.first)
    expect(entry).to include(
      "provider" => "dreamhost", "alias" => "dh", "action" => "add", "zone" => "example.com",
      "name" => "www", "type" => "A", "value" => "1.2.3.4", "ttl" => 300
    )
    expect(entry["timestamp"]).to match(/\A\d{4}-\d{2}-\d{2}T/)
  end

  it "appends subsequent calls as additional lines" do
    log = described_class.new(config: config, path: path)

    log.add(alias_name: "dh", action: "add", zone: "example.com",
            record: { "name" => "a", "type" => "A", "value" => "1.1.1.1" })
    log.add(alias_name: "dh", action: "remove", zone: "example.com",
            record: { "name" => "a", "type" => "A", "value" => "1.1.1.1" })

    expect(entries.map { |e| e["action"] }).to eq(%w[add remove])
  end

  it "shifts out the oldest entry once log_max_records is exceeded, instead of rotating the whole log" do
    write_config(<<~TOML)
      log_max_records = 3
      default_source = "dh"

      [sources.dh]
      provider = "dreamhost"
    TOML
    log = described_class.new(config: Denise::Config.new, path: path)

    5.times do |i|
      log.add(alias_name: "dh", action: "add", zone: "example.com",
              record: { "name" => "r#{i}", "type" => "A", "value" => "1.2.3.#{i}" })
    end

    expect(entries.map { |e| e["name"] }).to eq(%w[r2 r3 r4])
  end
end
