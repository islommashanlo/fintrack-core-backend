# frozen_string_literal: true

class CusipSecurityMapping < ApplicationRecord
  SOURCES = %w[openfigi].freeze
  STATUSES = %w[mapped unmapped ambiguous error stale].freeze
  NATURAL_KEY = %i[cusip source result_seq].freeze

  belongs_to :security, optional: true

  validates :cusip, presence: true, format: { with: /\A[0-9A-Z]{9}\z/ }
  validates :source, inclusion: { in: SOURCES }
  validates :result_seq, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :status, inclusion: { in: STATUSES }
  validates :last_checked_at, :first_seen_at, presence: true
end
