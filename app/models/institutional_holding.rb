# frozen_string_literal: true

class InstitutionalHolding < ApplicationRecord
  NATURAL_KEY = %i[institutional_report_id row_seq].freeze

  belongs_to :institutional_report

  validates :row_seq, presence: true, numericality: { only_integer: true, greater_than: 0 }
  validates :row_seq, uniqueness: { scope: :institutional_report_id }
  validates :name_of_issuer, :title_of_class, :value_reported, :value_unit, :shares, :share_type, presence: true
end
