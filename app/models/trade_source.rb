# frozen_string_literal: true

class TradeSource < ApplicationRecord
  # Enum for source types
  enum source_type: {
    politician: 'politician',
    hedge_fund: 'hedge_fund',
    insider: 'insider'
  }

  validates :name, presence: true, length: { maximum: 255 }
  validates :source_type, presence: true, inclusion: { in: source_types.keys }

  has_many :trades, dependent: :destroy

  # Scope methods for filtering
  scope :politicians, -> { where(source_type: :politician) }
  scope :hedge_funds, -> { where(source_type: :hedge_fund) }
  scope :insiders, -> { where(source_type: :insider) }

  def self.ransackable_attributes(_auth_object = nil)
    %w[name source_type]
  end

  def self.ransackable_associations(_auth_object = nil)
    %w[trades]
  end
end
