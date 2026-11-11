# frozen_string_literal: true

class InstitutionalReportOtherManager < ApplicationRecord
  NATURAL_KEY = %i[institutional_report_id sequence_no].freeze

  belongs_to :institutional_report

  validates :sequence_no, presence: true, numericality: { only_integer: true, greater_than: 0 }
  validates :sequence_no, uniqueness: { scope: :institutional_report_id }
end
