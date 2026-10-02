# frozen_string_literal: true

# Plain-text table for rake task output.
module TextTable
  module_function

  # rows: array of hashes; columns: { "Heading" => key or callable }
  def render(rows, columns)
    return "(none)" if rows.empty?

    cells = rows.map { |row| columns.values.map { |source| format_cell(source.respond_to?(:call) ? source.call(row) : row[source]) } }
    widths = columns.keys.each_with_index.map { |heading, i| [ heading.length, *cells.map { |c| c[i].length } ].max }

    lines = [ columns.keys, widths.map { |w| "-" * w }, *cells ].map do |line|
      line.each_with_index.map { |cell, i| cell.ljust(widths[i]) }.join("  ").rstrip
    end
    lines.join("\n")
  end

  def format_cell(value)
    case value
    when nil then "-"
    when BigDecimal then value.frac.zero? ? value.to_i.to_s : value.round(4).to_s("F")
    when Time then value.utc.strftime("%Y-%m-%d %H:%M")
    when true then "yes"
    when false then "no"
    else value.to_s
    end
  end
end
