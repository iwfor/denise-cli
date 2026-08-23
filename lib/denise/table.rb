# frozen_string_literal: true

module Denise
  # Renders the CLI's tabular output (`list-records`, `search`, `list-zones`, ...).
  #
  # Replaces Thor's own #print_table, which pads every column but the last to a
  # fixed width - so a row whose trailing cells are empty still ends in a long
  # run of spaces. With a column as wide as a DKIM TXT value that padding alone
  # is wider than the terminal, and every row soft-wraps into what reads as a
  # blank line between records. So: drop columns that are empty for every row
  # (DreamHost never reports a TTL, so `list-records` always had one), and strip
  # the trailing padding off each line.
  module Table
    SEPARATOR = "  "

    module_function

    def print(rows, indent: 0)
      lines(rows, indent: indent).each { |line| puts line }
    end

    # `rows.first` is the header row; returns the formatted lines, ready to print.
    def lines(rows, indent: 0)
      rows = drop_empty_columns(rows)
      widths = column_widths(rows)
      rows.map do |row|
        cells = row.each_with_index.map { |cell, index| cell.to_s.ljust(widths[index]) }
        "#{' ' * indent}#{cells.join(SEPARATOR).rstrip}"
      end
    end

    # A column is dropped only on the strength of the body rows: a header alone
    # ("TTL") isn't worth 400 columns of padding on every row beneath it.
    def drop_empty_columns(rows)
      header, *body = rows
      return rows if body.empty?

      keep = header.each_index.select { |index| body.any? { |row| !row[index].to_s.empty? } }
      return rows if keep.empty?

      rows.map { |row| keep.map { |index| row[index] } }
    end

    def column_widths(rows)
      return [] if rows.empty?

      rows.first.each_index.map { |index| rows.map { |row| row[index].to_s.length }.max }
    end
  end
end
