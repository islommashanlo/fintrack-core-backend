# frozen_string_literal: true

class PriceDaily < ApplicationRecord
  self.table_name = "prices_daily"
  NATURAL_KEY = %i[price_series_id session_date].freeze

  belongs_to :price_series

  validates :session_date, :observed_at, presence: true
  validates :session_date, uniqueness: { scope: :price_series_id }
  validates :open, :high, :low, :close, numericality: { greater_than: 0 }
  validates :volume, numericality: { greater_than_or_equal_to: 0 }
  validate :ohlc_range
  validate :integral_volume

  attr_readonly :price_series_id, :session_date, :open, :high, :low, :close, :volume, :observed_at

  private

  def integral_volume
    return if volume.nil?

    errors.add(:volume, "must be a finite integer") unless volume.finite? && volume.frac.zero?
  end

  def ohlc_range
    values = [ open, high, low, close ]
    return if values.any?(&:nil?)

    unless values.all?(&:finite?) && high >= [ open, close ].max && low <= [ open, close ].min
      errors.add(:base, "Invalid OHLC range")
    end
  end
end
