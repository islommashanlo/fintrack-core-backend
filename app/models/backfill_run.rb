# frozen_string_literal: true

# Progress of the daily-index backfill, one row per calendar day.
class BackfillRun < ApplicationRecord
  STATUSES = %w[pending running done no_index failed].freeze

  # Uniqueness of day is enforced by the unique index, which is what create_or_find_by! relies on.
  validates :day, presence: true
  validates :status, inclusion: { in: STATUSES }
end
