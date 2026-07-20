# frozen_string_literal: true

source "https://rubygems.org"

gem "base64"  # no longer a default gem as of Ruby 3.4
gem "faraday" # HTTP client for provider APIs
gem "reline"  # used by Thor's yes?/ask prompts; bundled, not default, as of Ruby 4.0
gem "thor"    # CLI framework

group :development, :test do
  gem "bundler-audit", "0.9.3" # checks dependencies against the ruby-advisory-db
  gem "rspec"
  gem "rubocop", "1.88.2"
end

gem "tomlib", "~> 0.7.3"
