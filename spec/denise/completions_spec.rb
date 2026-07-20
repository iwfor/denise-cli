# frozen_string_literal: true

require "tempfile"

RSpec.describe Denise::Completions do
  describe ".commands" do
    it "lists every CLI command except help, hyphenated" do
      expect(described_class.commands).to include("add-entry", "add-provider", "config", "refresh-zones")
      expect(described_class.commands).not_to include("help")
    end
  end

  describe ".top_level" do
    it "includes every command plus --completions and -h/--help" do
      top_level = described_class.top_level

      expect(top_level).to include(*described_class.commands, "--completions", "-h", "--help")
    end
  end

  describe ".flags_for" do
    it "includes a command's own options and the global class options" do
      flags = described_class.flags_for("add-entry")

      expect(flags).to include("-z", "--zone", "--type", "--value", "--ttl", "-p", "--provider", "-v", "--verbose")
    end

    it "returns only the global class options for a command with none of its own" do
      expect(described_class.flags_for("list-providers")).to contain_exactly("-p", "--provider", "-v", "--verbose")
    end

    it "returns an empty array for an unknown command" do
      expect(described_class.flags_for("nope")).to eq([])
    end
  end

  describe ".bash_script" do
    it "lists every command plus --completions and -h/--help at the top level" do
      script = described_class.bash_script

      expect(script).to include("add-entry add-provider add-zone config")
      expect(script).to include("--completions -h --help")
    end

    it "has a case branch offering each command's flags" do
      script = described_class.bash_script

      expect(script).to include('add-entry) COMPREPLY=($(compgen -W "-z --zone --type --value --ttl ' \
                                '-p --provider -v --verbose" -- "$cur")) ;;')
    end

    it "is syntactically valid bash" do
      Tempfile.create(["denise_completion", ".bash"]) do |file|
        file.write(described_class.bash_script)
        file.flush
        system("bash", "-n", file.path, exception: true)
      end
    end
  end

  describe ".zsh_script" do
    it "lists every command plus --completions and -h/--help at the top level" do
      script = described_class.zsh_script

      expect(script).to include("add-entry add-provider add-zone config")
      expect(script).to include("--completions -h --help")
    end

    it "has a case branch offering each command's flags" do
      script = described_class.zsh_script

      expect(script).to include("add-entry) flags=(-z --zone --type --value --ttl -p --provider -v --verbose) ;;")
    end

    it "is syntactically valid zsh" do
      Tempfile.create(["denise_completion", ".zsh"]) do |file|
        file.write(described_class.zsh_script)
        file.flush
        system("zsh", "-n", file.path, exception: true)
      end
    end
  end
end
