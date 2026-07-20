# frozen_string_literal: true

module Denise
  module Providers
    KNOWN = {
      "cloudflare" => { default_alias: "cf" },
      "dreamhost" => { default_alias: "dh" }
    }.freeze

    module_function

    def names
      KNOWN.keys
    end

    def known?(name)
      KNOWN.key?(name)
    end

    def default_alias(name)
      KNOWN.fetch(name).fetch(:default_alias)
    end
  end
end
