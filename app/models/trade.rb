# frozen_string_literal: true

class Trade < ApplicationRecord
  self.table_name = 'trades'

  belongs_to :trade_source, class_name: 'TradeSource'

  # Enum for transaction types
  enum transaction_type: {
    buy: 'buy',
    sell: 'sell'
  }

  validates :filing_date, presence: true
  validates :trade_date, presence: true
  validates :asset_name, presence: true, length: { maximum: 255 }
  validates :ticker, presence: true, length: { maximum: 10 }
  validates :amount, presence: true, numericality: { greater_than: 0 }
  validates :transaction_type, presence: true, inclusion: { in: transaction_types.keys }
  validates :disclosure_url, length: { maximum: 500 }, allow_blank: true

  # Scope methods for filtering
  scope :recent, -> { order(trade_date: :desc) }
  scope :by_ticker, ->(ticker) { where(ticker: ticker) }
  scope :by_source_type, ->(source_type) { joins(:trade_source).where(trade_sources: { source_type: source_type }) }
  scope :by_date_range, ->(start_date, end_date) { where(trade_date: start_date..end_date) }

  def self.ransackable_attributes(_auth_object = nil)
    %w[filing_date trade_date asset_name ticker amount transaction_type]
  end

  def self.ransackable_associations(_auth_object = nil)
    %w[trade_source]
  end

  # Custom ransack predicates for complex queries
  ransacker :trade_date do
    Arel.sql('trade_date')
  end

  ransacker :filing_date do
    Arel.sql('filing_date')
  end
end
