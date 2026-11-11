# frozen_string_literal: true

class InstitutionalReport < ApplicationRecord
  STATUSES = %w[pending parsed failed skipped].freeze

  belongs_to :filing
  belongs_to :institutional_filer
  has_many :institutional_report_other_managers, dependent: :restrict_with_exception
  has_many :institutional_report_managers, dependent: :restrict_with_exception
  has_many :institutional_holdings, dependent: :restrict_with_exception
  has_many :position_diffs, dependent: :restrict_with_exception
  has_many :prior_position_diffs, class_name: "PositionDiff", foreign_key: :prior_institutional_report_id,
                                    dependent: :restrict_with_exception, inverse_of: :prior_institutional_report

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

  # Returns the latest original/RESTATEMENT base plus later NEW HOLDINGS rows.
  # The supersession decision stays in SQL so callers cannot accidentally resolve a
  # point-in-time state by iterating reports in Ruby.
  def self.effective_holdings_for(institutional_filer:, period_of_report:)
    sql = sanitize_sql_array(
      [ <<~SQL, institutional_filer.id, period_of_report, institutional_filer.id, period_of_report ]
        WITH latest_base AS (
          SELECT r.id, COALESCE(r.filed_at, TIMESTAMP 'epoch') AS filed_at
          FROM institutional_reports r
          WHERE r.institutional_filer_id = ?
            AND r.period_of_report = ?
            AND r.status = 'parsed'
            AND (r.amendment_type IS NULL OR r.amendment_type = 'RESTATEMENT')
          ORDER BY r.filed_at DESC NULLS LAST, r.id DESC
          LIMIT 1
        ), effective_reports AS (
          SELECT id FROM latest_base
          UNION ALL
          SELECT r.id
          FROM institutional_reports r
          CROSS JOIN latest_base b
          WHERE r.institutional_filer_id = ?
            AND r.period_of_report = ?
            AND r.status = 'parsed'
            AND r.amendment_type = 'NEW HOLDINGS'
            AND COALESCE(r.filed_at, TIMESTAMP 'epoch') > b.filed_at
        )
        SELECT h.*
        FROM institutional_holdings h
        INNER JOIN effective_reports er ON er.id = h.institutional_report_id
        ORDER BY h.institutional_report_id, h.row_seq
      SQL
    )

    find_by_sql(sql)
  end
end
