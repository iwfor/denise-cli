# frozen_string_literal: true

require "thor"

module Denise
  # Class-level overrides of Thor's command dispatch, extended into
  # Denise::CLI. Kept out of CLI itself to stay under Metrics/ClassLength
  # (same pattern as RecordTypes/Search/ZoneSync). `super` here reaches
  # Thor's own implementations, since an extended module sits between CLI's
  # singleton class and Thor's.
  module CLIDispatch
    # Thor's built-in -h/--help only work as the very first word (it checks
    # HELP_MAPPINGS against argv[0] only), so `denise add-record -h` would
    # otherwise be parsed as an unrecognized option for add-record rather than
    # showing its help. Catch -h/--help anywhere in a command's own args and
    # redirect to `help COMMAND` before Thor's normal dispatch ever runs.
    def dispatch(meth, given_args, given_opts, config)
      command_name = given_args.first
      if meth.nil? && command_name && command_name !~ /\A-/ && given_args.intersect?(%w[-h --help])
        return super(nil, ["help", command_name], given_opts, config)
      end

      super
    end

    # Thor's own "Did you mean?" suggestions are built from its internal command
    # registry, which uses underscored method names (`list_records`), not the
    # hyphenated form every command is actually invoked with (`list-records`).
    # Translate the dictionary before Thor raises, so a typo like `list-source`
    # suggests something the user can actually type.
    # rubocop:disable Style/GlobalVars -- must match Thor's own
    # handle_no_command_error(command, has_namespace = $thor_runner) signature exactly.
    def handle_no_command_error(command, has_namespace = $thor_runner)
      raise Thor::UndefinedCommandError.new(command,
                                            all_commands.keys.map { |name| name.tr("_", "-") },
                                            (namespace if has_namespace))
    end
    # rubocop:enable Style/GlobalVars
  end
end
