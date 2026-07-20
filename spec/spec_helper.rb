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

# Swallows Thor's say/print_table/warn output so CLI specs don't spam the
# real terminal; the specs assert on state and mock calls, not on text.
def silence_output
  original_stdout = $stdout
  original_stderr = $stderr
  $stdout = File.open(File::NULL, "w")
  $stderr = File.open(File::NULL, "w")
  yield
ensure
  $stdout = original_stdout
  $stderr = original_stderr
end
