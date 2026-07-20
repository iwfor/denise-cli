# frozen_string_literal: true

require_relative "../lib/denise"
require "tmpdir"

RSpec.configure do |config|
  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.around do |example|
    Dir.mktmpdir("denise-spec") do |dir|
      ENV["DENISE_CONFIG_DIR"] = dir
      example.run
    end
    ENV.delete("DENISE_CONFIG_DIR")
  end
end
