# frozen_string_literal: true

RSpec.describe Denise::Table do
  describe ".print" do
    it "writes each formatted line to stdout" do
      output = capture_stdout { described_class.print([%w[NAME TYPE], %w[www A]]) }

      expect(output).to eq("NAME  TYPE\nwww   A\n")
    end
  end

  describe ".lines" do
    it "pads columns to a common width" do
      lines = described_class.lines([%w[NAME TYPE], %w[www A], %w[mailboxes CNAME]])

      expect(lines).to eq(
        [
          "NAME       TYPE",
          "www        A",
          "mailboxes  CNAME"
        ]
      )
    end

    it "never leaves trailing whitespace on a line" do
      lines = described_class.lines([%w[ALIAS PROVIDER DEFAULT], ["dh", "dreamhost", "*"], ["cf", "cloudflare", ""]])

      expect(lines).to all(satisfy { |line| line == line.rstrip })
      expect(lines.last).to eq("cf     cloudflare")
    end

    it "drops a column that is empty for every record" do
      rows = [%w[NAME TYPE VALUE TTL],
              ["www", "A", "1.2.3.4", nil],
              ["mail", "MX", "0 mx1.example.com.", nil]]

      expect(described_class.lines(rows)).to eq(
        [
          "NAME  TYPE  VALUE",
          "www   A     1.2.3.4",
          "mail  MX    0 mx1.example.com."
        ]
      )
    end

    it "keeps a column that is empty for only some records" do
      rows = [%w[NAME TYPE TTL], ["www", "A", 300], ["mail", "MX", nil]]

      expect(described_class.lines(rows)).to eq(["NAME  TYPE  TTL", "www   A     300", "mail  MX"])
    end

    it "keeps every column when there are no records to judge them by" do
      expect(described_class.lines([%w[NAME TYPE TTL]])).to eq(["NAME  TYPE  TTL"])
    end

    it "keeps every column when all of them are empty" do
      expect(described_class.lines([%w[NAME TTL], ["", nil]])).to eq(["NAME  TTL", ""])
    end

    it "indents every line by the given amount" do
      lines = described_class.lines([["-h, --help", "Show this help"]], indent: 2)

      expect(lines).to eq(["  -h, --help  Show this help"])
    end

    it "returns nothing for an empty table" do
      expect(described_class.lines([])).to eq([])
    end
  end
end
