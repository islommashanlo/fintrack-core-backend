# frozen_string_literal: true

# Progress of the daily-index backfill, one row per calendar day.
class BackfillRun < ApplicationRecord
  STATUSES = %w[pending running done no_index failed].freeze

  validates :day, presence: true, uniqueness: true
  validates :status, inclusion: { in: STATUSES }
end
