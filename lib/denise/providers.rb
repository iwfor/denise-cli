# frozen_string_literal: true

module Denise
  module Providers
    KNOWN = {
      "cloudflare" => { default_alias: "cf" },
      "dreamhost" => { default_alias: "dh" },
      "aws" => { default_alias: "aws" }
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

    def client_for(name, token:)
      raise UnknownProviderError, name unless known?(name)

      case name
      when "cloudflare" then Cloudflare.new(token: token)
      when "dreamhost" then Dreamhost.new(token: token)
      when "aws" then Aws.new(token: token)
      end
    end
  end
end
