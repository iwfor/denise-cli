# frozen_string_literal: true

module Denise
  module Paths
    module_function

    def config_dir
      File.expand_path(ENV.fetch("DENISE_CONFIG_DIR", "~/.config/denise-cli"))
    end

    def config_file
      File.join(config_dir, "config.toml")
    end

    def key_file
      File.join(config_dir, "key")
    end
  end
end
