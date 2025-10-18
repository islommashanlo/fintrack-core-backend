# frozen_string_literal: true

class AlertPreference < ApplicationRecord
  belongs_to :user

  # Enum for source types
  enum source_type: {
    politician: 'politician',
    hedge_fund: 'hedge_fund',
    insider: 'insider'
  }

  validates :ticker, presence: true, length: { maximum: 10 }
  validates :source_type, inclusion: { in: source_types.keys }, allow_blank: true
  validates :person_name, length: { maximum: 255 }, allow_blank: true
  validates :user_id, uniqueness: { scope: %i[ticker source_type person_name] }

  scope :active, -> { where(active: true) }
  scope :by_ticker, ->(ticker) { where(ticker: ticker) }
  scope :by_source_type, ->(source_type) { where(source_type: source_type) }
  scope :by_person, ->(person_name) { where(person_name: person_name) }

  def matches_trade?(trade)
    # Check if this preference matches the given trade
    return false unless active

    # Check ticker match
    return false unless ticker_match?(trade.ticker)

    # Check source type match if specified
    return false if source_type.present? && trade.trade_source.source_type != source_type

    # Check person name match if specified
    return false if person_name.present? && trade.trade_source.name != person_name

    true
  end

  private

  def ticker_match?(trade_ticker)
    # Simple ticker matching - in a real app you might want more sophisticated matching
    ticker.upcase == trade_ticker.upcase
  end

  def self.ransackable_attributes(_auth_object = nil)
    %w[ticker source_type person_name active]
  end

  def self.ransackable_associations(_auth_object = nil)
    %w[user]
  end
end
