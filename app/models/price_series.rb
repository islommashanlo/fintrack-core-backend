# frozen_string_literal: true

class PriceSeries < ApplicationRecord
  ADJUSTMENTS = %w[unadjusted split_adjusted].freeze
  IDENTITY = %i[security_id provider provider_symbol currency adjustment].freeze

  belongs_to :security
  has_many :prices_daily, class_name: "PriceDaily", dependent: :restrict_with_exception

  validates :provider, format: { with: /\A[a-z][a-z0-9_]{0,39}\z/ }
  validates :provider_symbol, presence: true, length: { maximum: 100 }
  validates :currency, format: { with: /\A[A-Z]{3}\z/ }
  validates :adjustment, inclusion: { in: ADJUSTMENTS }
  validates :provider_symbol, uniqueness: { scope: %i[security_id provider currency adjustment] }

  # Changing symbol, currency or basis creates another series; historical rows
  # must never acquire a different meaning after a ticker/provider change.
  attr_readonly(*IDENTITY)
end
