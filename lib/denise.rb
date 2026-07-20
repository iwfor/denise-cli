# frozen_string_literal: true

require_relative "denise/version"
require_relative "denise/paths"
require_relative "denise/providers"
require_relative "denise/errors"
require_relative "denise/providers/base"
require_relative "denise/providers/cloudflare"
require_relative "denise/providers/dreamhost"
require_relative "denise/providers/aws"
require_relative "denise/crypto"
require_relative "denise/config"
require_relative "denise/completions"
require_relative "denise/record_types"
require_relative "denise/search"
require_relative "denise/cli"

module Denise
  class << self
    # Set from -v/--verbose by Denise::CLI; read by provider clients to
    # decide whether to print request/response diagnostics. Never gates
    # anything that touches token/secret values - see Providers::Base#log.
    attr_accessor :verbose
  end

  self.verbose = false
end
