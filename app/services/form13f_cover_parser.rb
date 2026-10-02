# frozen_string_literal: true

# Parses a 13F cover document into plain value objects.
#
# Pure (invariant 7): XML string in, Ruby objects out, no database or network access.
# XPath expressions use local-name so the parser accepts the namespace prefixes used by
# different EDGAR filings without depending on a particular prefix.
class Form13fCoverParser
  class MalformedError < StandardError; end

  Cover = Data.define(
    :submission_type, :period_of_report, :is_amendment, :amendment_number, :amendment_type, :report_type,
    :filer, :other_managers, :included_managers, :other_included_managers_count,
    :table_entry_total, :table_value_total, :is_confidential_omitted
  )

  Filer = Data.define(:cik, :name, :form13f_file_number, :crd_number, :sec_file_number)

  Manager = Data.define(
    :sequence_no, :cik, :name, :form13f_file_number, :crd_number, :sec_file_number
  )

  TRUE_VALUES = %w[1 true].freeze
  FALSE_VALUES = %w[0 false].freeze

  def self.parse(xml)
    new(xml).parse
  end

  def initialize(xml)
    @xml = xml.to_s
  end

  def parse
    submission_type = required(root, "headerData/submissionType")
    cover_page = required_node(root, "formData/coverPage")
    summary_page = optional_node(root, "formData/summaryPage")

    Cover.new(
      submission_type: submission_type,
      period_of_report: date(required(root, "headerData/filerInfo/periodOfReport"), "periodOfReport"),
      is_amendment: boolean(text(cover_page, "isAmendment")) || submission_type.end_with?("/A"),
      amendment_number: integer(text(cover_page, "amendmentNo"), "amendmentNo"),
      amendment_type: text(cover_page, "amendmentInfo/amendmentType"),
      report_type: required(cover_page, "reportType"),
      filer: filer(cover_page),
      other_managers: managers(cover_page, "otherManagersInfo/otherManager"),
      included_managers: included_managers(summary_page),
      other_included_managers_count: integer(text(summary_page, "otherIncludedManagersCount"), "otherIncludedManagersCount"),
      table_entry_total: integer(text(summary_page, "tableEntryTotal"), "tableEntryTotal"),
      table_value_total: decimal(text(summary_page, "tableValueTotal"), "tableValueTotal"),
      is_confidential_omitted: boolean(text(summary_page, "isConfidentialOmitted"))
    )
  end

  private

  def root
    @root ||= begin
      raise MalformedError, "empty document" if @xml.strip.empty?

      document = Nokogiri::XML(@xml) { |config| config.strict.nonet }
      node = document.root
      raise MalformedError, "root element is #{node&.name.inspect}, not edgarSubmission" unless local_name(node) == "edgarSubmission"

      node
    end
  rescue Nokogiri::XML::SyntaxError => e
    raise MalformedError, "invalid XML: #{e.message}"
  end

  def filer(cover_page)
    Filer.new(
      cik: cik(required(root, "headerData/filerInfo/filer/credentials/cik")),
      name: required(cover_page, "filingManager/name"),
      form13f_file_number: text(cover_page, "form13FFileNumber"),
      crd_number: text(cover_page, "crdNumber"),
      sec_file_number: text(cover_page, "secFileNumber")
    )
  end

  def managers(cover_page, path)
    nodes(cover_page, path).each_with_index.map do |node, index|
      manager(node, index + 1)
    end
  end

  def included_managers(summary_page)
    return [] unless summary_page

    nodes(summary_page, "otherManagers2Info/otherManager2").map do |wrapper|
      node = optional_node(wrapper, "otherManager") || wrapper
      manager(node, integer(text(wrapper, "sequenceNumber"), "sequenceNumber"))
    end
  end

  def manager(node, sequence_no)
    Manager.new(
      sequence_no: sequence_no,
      cik: optional_cik(text(node, "cik")),
      name: text(node, "name"),
      form13f_file_number: text(node, "form13FFileNumber"),
      crd_number: text(node, "crdNumber"),
      sec_file_number: text(node, "secFileNumber")
    )
  end

  def optional_node(node, path)
    node && at_path(node, path)
  end

  def required_node(node, path)
    optional_node(node, path) || raise(MalformedError, "missing #{path}")
  end

  def nodes(node, path)
    path.split("/").reduce([ node ]) do |current, part|
      current.flat_map { |parent| parent.xpath("./*[local-name()='#{part}']") }
    end
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

  def optional_cik(value)
    value && cik(value)
  end

  def cik(value)
    Cik.normalize(value)
  rescue ArgumentError
    raise MalformedError, "not a CIK: #{value.inspect}"
  end

  def integer(value, field)
    return nil if value.nil?

    Integer(value, 10)
  rescue ArgumentError
    raise MalformedError, "#{field} is not an integer: #{value.inspect}"
  end

  def decimal(value, field)
    return nil if value.nil?

    BigDecimal(value)
  rescue ArgumentError
    raise MalformedError, "#{field} is not a number: #{value.inspect}"
  end

  def date(value, field)
    Date.strptime(value, "%m-%d-%Y")
  rescue Date::Error
    raise MalformedError, "#{field} is not a date: #{value.inspect}"
  end

  def boolean(value)
    return nil if value.nil?

    normalized = value.downcase
    return true if TRUE_VALUES.include?(normalized)
    return false if FALSE_VALUES.include?(normalized)

    raise MalformedError, "boolean is invalid: #{value.inspect}"
  end

  def local_name(node)
    node&.name&.split(":", 2)&.last
  end
end
