# frozen_string_literal: true

class InsiderTransaction < ApplicationRecord
  SECURITY_TABLES = %w[non_derivative derivative].freeze
  NATURAL_KEY = %i[accession_no insider_cik security_table txn_seq].freeze
  NATURAL_KEY_INDEX = :index_insider_transactions_on_natural_key

  # Open-market trades; the only codes where the reported price is a market price.
  PURCHASE_CODE = "P"
  SALE_CODE = "S"
  OPEN_MARKET_CODES = [ PURCHASE_CODE, SALE_CODE ].freeze

  belongs_to :filing

  def open_market?
    OPEN_MARKET_CODES.include?(transaction_code)
  end

  def direction
    return "purchase" if transaction_code == PURCHASE_CODE
    return "sale" if transaction_code == SALE_CODE

    "other"
  end

  def reported_value
    shares * price if shares && price && !price_suspect
  end

  validates :security_table, inclusion: { in: SECURITY_TABLES }
  validates :accession_no, :insider_cik, :issuer_cik, :txn_seq, :owner_seq, presence: true
end
