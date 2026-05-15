# frozen_string_literal: true

class TradeSource < ApplicationRecord
  enum source_type: {
    politician:  'politician',
    hedge_fund:  'hedge_fund',
    insider:     'insider',
    institution: 'institution',  # Broad institutional: asset managers, banks, pension funds
    hnwi:        'hnwi'          # High Net Worth Individual
  }

  validates :name,        presence: true, length: { maximum: 255 }
  validates :source_type, presence: true, inclusion: { in: source_types.keys }

  has_many :trades,                dependent: :destroy
  has_many :institutional_holdings, dependent: :destroy

  scope :politicians,   -> { where(source_type: :politician) }
  scope :hedge_funds,   -> { where(source_type: :hedge_fund) }
  scope :insiders,      -> { where(source_type: :insider) }
  scope :institutions,  -> { where(source_type: :institution) }
  scope :hnwis,         -> { where(source_type: :hnwi) }

  def self.ransackable_attributes(_auth_object = nil)
    %w[name source_type institution_type net_worth_tier]
  end

  def self.ransackable_associations(_auth_object = nil)
    %w[trades institutional_holdings]
  end
end
