# frozen_string_literal: true

class InstitutionalHolding < ApplicationRecord
  belongs_to :trade_source

  validates :period_of_report, presence: true
  validates :ticker, presence: true, length: { maximum: 20 }
  validates :value, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :shares, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true

  scope :for_period,  ->(period) { where(period_of_report: period) }
  scope :for_ticker,  ->(ticker) { where(ticker: ticker) }
  scope :by_value,    -> { order(value: :desc) }
  scope :recent,      -> { order(filing_date: :desc) }

  def self.ransackable_attributes(_auth_object = nil)
    %w[period_of_report ticker company_name value shares filing_date]
  end

  def self.ransackable_associations(_auth_object = nil)
    %w[trade_source]
  end
end
