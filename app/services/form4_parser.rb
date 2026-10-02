# frozen_string_literal: true

# Parses a Form 4 or 4/A ownership XML document into plain value objects.
#
# Pure (invariant 7): XML string in, Ruby objects out, no database or network access.
# Values are returned exactly as reported; nothing is corrected or derived here.
# Element names were taken from real filings (schema X0609; see spec/fixtures/filings/form4).
class Form4Parser
  class MalformedError < StandardError; end

  Document = Data.define(
    :document_type, :schema_version, :period_of_report, :date_of_original_submission,
    :aff10b5_one, :issuer, :owners, :transactions, :footnotes
  ) do
    def amendment?
      document_type.end_with?("/A")
    end
  end

  Issuer = Data.define(:cik, :name, :ticker)

  Owner = Data.define(
    :cik, :name, :is_director, :is_officer, :is_ten_percent_owner, :is_other, :officer_title
  )

  Transaction = Data.define(
    :security_table, :txn_seq, :security_title, :transaction_date, :deemed_execution_date,
    :transaction_code, :transaction_form_type, :equity_swap_involved, :transaction_timeliness,
    :shares, :price, :acquired_disposed, :shares_owned_following, :direct_or_indirect,
    :nature_of_ownership, :conversion_or_exercise_price, :exercise_date, :expiration_date,
    :underlying_security_title, :underlying_security_shares, :footnote_ids
  )

  TABLES = {
    "non_derivative" => "nonDerivativeTable/nonDerivativeTransaction",
    "derivative" => "derivativeTable/derivativeTransaction"
  }.freeze

  TRUE_VALUES = %w[1 true].freeze
  FALSE_VALUES = %w[0 false].freeze

  def self.parse(xml)
    new(xml).parse
  end

  def initialize(xml)
    @xml = xml.to_s
  end

  def parse
    Document.new(
      document_type: required(root, "documentType"),
      schema_version: text(root, "schemaVersion"),
      period_of_report: date(required(root, "periodOfReport"), "periodOfReport"),
      date_of_original_submission: date(text(root, "dateOfOriginalSubmission"), "dateOfOriginalSubmission"),
      aff10b5_one: boolean(text(root, "aff10b5One"), "aff10b5One"),
      issuer: issuer,
      owners: owners,
      transactions: transactions,
      footnotes: footnotes
    )
  end

  private

  def root
    @root ||= begin
      raise MalformedError, "empty document" if @xml.strip.empty?

      node = Nokogiri::XML(@xml) { |config| config.strict.nonet }.root
      raise MalformedError, "root element is #{node&.name.inspect}, not ownershipDocument" unless node&.name == "ownershipDocument"

      node
    end
  rescue Nokogiri::XML::SyntaxError => e
    raise MalformedError, "invalid XML: #{e.message}"
  end

  def issuer
    node = root.at_xpath("issuer") || raise(MalformedError, "missing issuer")

    Issuer.new(
      cik: cik(required(node, "issuerCik")),
      name: text(node, "issuerName"),
      ticker: text(node, "issuerTradingSymbol")
    )
  end

  def owners
    nodes = root.xpath("reportingOwner")
    raise MalformedError, "no reportingOwner" if nodes.empty?

    nodes.map do |node|
      relationship = node.at_xpath("reportingOwnerRelationship")

      Owner.new(
        cik: cik(required(node, "reportingOwnerId/rptOwnerCik")),
        name: text(node, "reportingOwnerId/rptOwnerName"),
        is_director: flag(relationship, "isDirector"),
        is_officer: flag(relationship, "isOfficer"),
        is_ten_percent_owner: flag(relationship, "isTenPercentOwner"),
        is_other: flag(relationship, "isOther"),
        officer_title: relationship && text(relationship, "officerTitle")
      )
    end
  end

  def transactions
    TABLES.flat_map do |table, path|
      root.xpath(path).each_with_index.map { |node, index| transaction(node, table, index + 1) }
    end
  end

  def transaction(node, table, seq)
    Transaction.new(
      security_table: table,
      txn_seq: seq,
      security_title: value(node, "securityTitle"),
      transaction_date: date(value(node, "transactionDate"), "transactionDate"),
      deemed_execution_date: date(value(node, "deemedExecutionDate"), "deemedExecutionDate"),
      transaction_code: text(node, "transactionCoding/transactionCode"),
      transaction_form_type: text(node, "transactionCoding/transactionFormType"),
      equity_swap_involved: boolean(text(node, "transactionCoding/equitySwapInvolved"), "equitySwapInvolved"),
      transaction_timeliness: value(node, "transactionTimeliness"),
      shares: decimal(value(node, "transactionAmounts/transactionShares"), "transactionShares"),
      price: decimal(value(node, "transactionAmounts/transactionPricePerShare"), "transactionPricePerShare"),
      acquired_disposed: value(node, "transactionAmounts/transactionAcquiredDisposedCode"),
      shares_owned_following: decimal(
        value(node, "postTransactionAmounts/sharesOwnedFollowingTransaction"), "sharesOwnedFollowingTransaction"
      ),
      direct_or_indirect: value(node, "ownershipNature/directOrIndirectOwnership"),
      nature_of_ownership: value(node, "ownershipNature/natureOfOwnership"),
      conversion_or_exercise_price: decimal(value(node, "conversionOrExercisePrice"), "conversionOrExercisePrice"),
      exercise_date: date(value(node, "exerciseDate"), "exerciseDate"),
      expiration_date: date(value(node, "expirationDate"), "expirationDate"),
      underlying_security_title: value(node, "underlyingSecurity/underlyingSecurityTitle"),
      underlying_security_shares: decimal(
        value(node, "underlyingSecurity/underlyingSecurityShares"), "underlyingSecurityShares"
      ),
      footnote_ids: node.xpath(".//footnoteId/@id").map(&:value).uniq
    )
  end

  def footnotes
    root.xpath("footnotes/footnote").to_h { |node| [ node["id"], node.text.strip ] }
  end

  # Text of an element, or nil when it is absent or blank.
  def text(node, path)
    node.at_xpath(path)&.text&.strip.presence
  end

  # Most reported fields wrap their content in a <value> child, next to optional footnote references.
  def value(node, path)
    text(node, "#{path}/value")
  end

  def required(node, path)
    text(node, path) || raise(MalformedError, "missing #{path}")
  end

  def cik(string)
    Cik.normalize(string)
  rescue ArgumentError
    raise MalformedError, "not a CIK: #{string.inspect}"
  end

  def decimal(string, field)
    return nil if string.nil?

    BigDecimal(string)
  rescue ArgumentError
    raise MalformedError, "#{field} is not a number: #{string.inspect}"
  end

  # Dates are YYYY-MM-DD; a trailing zone offset, if any, is ignored.
  def date(string, field)
    return nil if string.nil?

    Date.iso8601(string[/\A\d{4}-\d{2}-\d{2}/] || raise(Date::Error))
  rescue Date::Error
    raise MalformedError, "#{field} is not a date: #{string.inspect}"
  end

  # Filers write booleans as 1/0 or true/false; both appear in real filings.
  def boolean(string, field)
    return nil if string.nil?
    return true if TRUE_VALUES.include?(string.downcase)
    return false if FALSE_VALUES.include?(string.downcase)

    raise MalformedError, "#{field} is not a boolean: #{string.inspect}"
  end

  # A relationship box that is absent is a box that was not ticked.
  def flag(relationship, name)
    return false if relationship.nil?

    boolean(text(relationship, name), name) || false
  end
end
