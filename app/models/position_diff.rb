# frozen_string_literal: true

class PositionDiff < ApplicationRecord
  CHANGE_TYPES = %w[new exit add trim].freeze
  NATURAL_KEY = %i[institutional_filer_id period_of_report cusip put_call share_type].freeze

  belongs_to :institutional_filer
  belongs_to :institutional_report
  belongs_to :prior_institutional_report, class_name: "InstitutionalReport", optional: true

  validates :period_of_report, :cusip, :put_call, :share_type, :change_type, :shares_delta,
            :calculated_at, presence: true
  validates :change_type, inclusion: { in: CHANGE_TYPES }
  validates :cusip, format: { with: /\A[0-9A-Z]{9}\z/ }
end
