# frozen_string_literal: true

# Source revisions are separate observations; never mutate a recorded value.
class IssuerScaleObservation < ApplicationRecord
  NATURAL_KEY = %i[issuer_cik source source_record_id source_revision].freeze

  validates :issuer_cik, format: { with: /\A[0-9]{10}\z/ }
  validates :source, format: { with: /\A[a-z][a-z0-9_]{0,39}\z/ }
  validates :currency, format: { with: /\A[A-Z]{3}\z/ }
  validates :source_record_id, presence: true, length: { maximum: 200 },
    uniqueness: { scope: %i[issuer_cik source source_revision] }
  validates :source_revision, :measurement_basis, presence: true, length: { maximum: 100 }
  validates :market_cap, numericality: { greater_than_or_equal_to: 0 }
  validates :effective_at, :observed_at, presence: true
  validate :finite_amount_and_times

  # All candidates remain visible; choosing between providers/bases is separate policy.
  scope :known_at, ->(time) { where("effective_at <= :time AND observed_at <= :time AND created_at <= :time", time:) }

  def readonly?
    persisted?
  end

  private

  def finite_amount_and_times
    errors.add(:market_cap, "must be finite") if market_cap && !market_cap.finite?
    if effective_at && observed_at && effective_at > observed_at
      errors.add(:effective_at, "must not follow observation time")
    end
    if observed_at && observed_at > (created_at || Time.current)
      errors.add(:observed_at, "must not follow recording time")
    end
  end
end
