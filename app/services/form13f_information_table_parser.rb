# frozen_string_literal: true

# Streams 13F information-table rows into plain value objects.
#
# A Reader is used for the outer table so a filing with tens of thousands of rows does
# not create one Nokogiri node tree for the entire document. Each individual row is
# materialized only long enough to read its fields.
class Form13fInformationTableParser
  class MalformedError < StandardError; end

  Holding = Data.define(
    :row_seq, :name_of_issuer, :title_of_class, :cusip, :value_reported, :shares, :share_type,
    :put_call, :investment_discretion, :other_manager, :voting_sole, :voting_shared,
    :voting_none, :figi
  )

  def self.parse(xml)
    new(xml).parse
  end

  def initialize(xml)
    @xml = xml.to_s
  end

  def parse
    raise MalformedError, "empty document" if @xml.strip.empty?

    rows = []
    root_name = nil
    reader = Nokogiri::XML::Reader(@xml) { |config| config.strict.nonet }
    reader.each do |node|
      next unless node.node_type == Nokogiri::XML::Reader::TYPE_ELEMENT

      root_name ||= node.local_name
      next unless node.local_name == "infoTable"

      rows << parse_row(node.outer_xml, rows.length + 1)
    end

    raise MalformedError, "root element is not informationTable" unless root_name == "informationTable"
    raise MalformedError, "no infoTable rows" if rows.empty?

    rows
  rescue Nokogiri::XML::SyntaxError => e
    raise MalformedError, "invalid XML: #{e.message}"
  end

  private

  def parse_row(xml, row_seq)
    node = Nokogiri::XML(xml) { |config| config.strict.nonet }.root

    Holding.new(
      row_seq: row_seq,
      name_of_issuer: required(node, "nameOfIssuer"),
      title_of_class: required(node, "titleOfClass"),
      cusip: required(node, "cusip"),
      value_reported: decimal(required(node, "value"), "value"),
      shares: decimal(required(node, "shrsOrPrnAmt/sshPrnamt"), "sshPrnamt"),
      share_type: required(node, "shrsOrPrnAmt/sshPrnamtType"),
      put_call: text(node, "putCall"),
      investment_discretion: text(node, "investmentDiscretion"),
      other_manager: text(node, "otherManager"),
      voting_sole: decimal(text(node, "votingAuthority/Sole"), "Sole"),
      voting_shared: decimal(text(node, "votingAuthority/Shared"), "Shared"),
      voting_none: decimal(text(node, "votingAuthority/None"), "None"),
      figi: text(node, "figi")
    )
  rescue Nokogiri::XML::SyntaxError => e
    raise MalformedError, "invalid XML: #{e.message}"
  end

  def at_path(node, path)
    path.split("/").reduce(node) do |current, part|
      current&.at_xpath("./*[local-name()='#{part}']")
    end
  end

  def text(node, path)
    at_path(node, path)&.text&.strip.presence
  end

  def required(node, path)
    text(node, path) || raise(MalformedError, "missing #{path}")
  end

  def decimal(value, field)
    return nil if value.nil?

    BigDecimal(value)
  rescue ArgumentError
    raise MalformedError, "#{field} is not a number: #{value.inspect}"
  end
end
