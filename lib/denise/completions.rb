# frozen_string_literal: true

module Denise
  module Completions
    module_function

    def print(shell = nil)
      shell ||= detect_shell
      case shell
      when "zsh"
        puts zsh_script
      when "bash"
        puts bash_script
      else
        warn "denise: unsupported shell '#{shell}' (expected bash or zsh)"
        exit 1
      end
    end

    def detect_shell
      File.basename(ENV.fetch("SHELL", "bash"))
    end

    def commands
      CLI.commands.keys.reject { |name| name == "help" }.map { |name| name.tr("_", "-") }.sort
    end

    def bash_script
      <<~BASH
        _denise_completions() {
          local cur="${COMP_WORDS[COMP_CWORD]}"
          COMPREPLY=($(compgen -W "#{commands.join(' ')}" -- "$cur"))
        }
        complete -F _denise_completions denise
      BASH
    end

    def zsh_script
      <<~ZSH
        #compdef denise

        _denise() {
          local -a commands
          commands=(#{commands.join(' ')})
          _describe 'command' commands
        }

        _denise
      ZSH
    end
  end
end
