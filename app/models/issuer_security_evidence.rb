# frozen_string_literal: true

# A source assertion, not an automatically verified historical identity.
class IssuerSecurityEvidence < ApplicationRecord
  NATURAL_KEY = %i[issuer_cik security_id source source_record_id source_revision].freeze

  belongs_to :security

  validates :issuer_cik, format: { with: /\A[0-9]{10}\z/ }
  validates :source, format: { with: /\A[a-z][a-z0-9_]{0,39}\z/ }
  validates :security_figi, presence: true, length: { maximum: 64 }
  validates :cusip, format: { with: /\A[0-9A-Z]{9}\z/ }, allow_nil: true
  validates :ticker, presence: true, length: { maximum: 40 }, unless: -> { ticker.nil? }
  validates :source_record_id, presence: true, length: { maximum: 200 },
    uniqueness: { scope: %i[issuer_cik security_id source source_revision] }
  validates :source_revision, presence: true, length: { maximum: 100 }
  validates :effective_from, :observed_at, presence: true
  validate :ordered_times
  validate :matching_local_identifier, on: :create

  # Independent economic and knowledge clocks; all overlapping assertions remain candidates.
  scope :applicable_at, ->(effective_at:, known_at:) do
    where("effective_from <= ? AND (effective_to IS NULL OR effective_to > ?) AND observed_at <= ? AND created_at <= ?",
      effective_at, effective_at, known_at, known_at)
  end

  def readonly?
    persisted?
  end

  private

  def ordered_times
    errors.add(:effective_to, "must follow interval start") if effective_to && effective_from && effective_to <= effective_from
    errors.add(:observed_at, "must not follow recording time") if observed_at && observed_at > (created_at || Time.current)
  end

  def matching_local_identifier
    errors.add(:security_figi, "must match the referenced local security at recording") if security && security_figi != security.figi
  end
end
