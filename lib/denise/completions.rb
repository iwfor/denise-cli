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

    # Every switch (short and long form) for a command's own options plus
    # the global class options (-p/--provider, -v/--verbose), so e.g.
    # `denise add-entry <TAB>` suggests --zone/--type/--value/--ttl too.
    # -h/--help are added explicitly: CLI.dispatch handles them for any
    # command, but they're not declared options, so they aren't in
    # command.options or CLI.class_options to be picked up automatically.
    def flags_for(command_name)
      command = CLI.commands[command_name.tr("-", "_")]
      return [] unless command

      switches = (command.options.values + CLI.class_options.values).flat_map { |opt| [*opt.aliases, opt.switch_name] }
      switches + ["-h", "--help"]
    end

    def bash_script
      <<~BASH
        _denise_completions() {
          local cur="${COMP_WORDS[COMP_CWORD]}"
          local cmd="${COMP_WORDS[1]}"

          if [ "$COMP_CWORD" -eq 1 ]; then
            COMPREPLY=($(compgen -W "#{top_level.join(' ')}" -- "$cur"))
            return
          fi

          if [ "$cmd" = "--completions" ]; then
            COMPREPLY=($(compgen -W "bash zsh" -- "$cur"))
            return
          fi

          case "$cmd" in
        #{bash_case_branches}
            *) COMPREPLY=() ;;
          esac
        }
        complete -F _denise_completions denise
      BASH
    end

    def zsh_script
      <<~ZSH
        #compdef denise

        _denise() {
          local -a commands
          commands=(#{top_level.join(' ')})

          if (( CURRENT == 2 )); then
            _describe 'command' commands
            return
          fi

          local cmd="${words[2]}"
          if [[ "$cmd" == "--completions" ]]; then
            local -a shells
            shells=(bash zsh)
            _describe 'shell' shells
            return
          fi

          local -a flags
          case "$cmd" in
        #{zsh_case_branches}
            *) flags=() ;;
          esac
          _describe 'flag' flags
        }

        _denise
      ZSH
    end

    def top_level
      commands + ["--completions", "-h", "--help"]
    end

    def bash_case_branches
      commands.map do |name|
        flags = flags_for(name).join(" ")
        "    #{name}) COMPREPLY=($(compgen -W \"#{flags}\" -- \"$cur\")) ;;"
      end.join("\n")
    end

    def zsh_case_branches
      commands.map { |name| "    #{name}) flags=(#{flags_for(name).join(' ')}) ;;" }.join("\n")
    end
  end
end
