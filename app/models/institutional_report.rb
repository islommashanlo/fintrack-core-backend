# frozen_string_literal: true

class InstitutionalReport < ApplicationRecord
  STATUSES = %w[pending parsed failed skipped].freeze

  belongs_to :filing
  belongs_to :institutional_filer
  has_many :institutional_report_managers, dependent: :restrict_with_exception
  has_many :institutional_holdings, dependent: :restrict_with_exception

  validates :period_of_report, :submission_type, :report_type, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :parsed, -> { where(status: "parsed") }
  scope :skipped, -> { where(status: "skipped") }

  def amendment?
    submission_type.end_with?("/A")
  end

  def skipped?
    status == "skipped"
  end

  def restatement?
    amendment_type == "RESTATEMENT"
  end

  def new_holdings?
    amendment_type == "NEW HOLDINGS"
  end
end
