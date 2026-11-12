# frozen_string_literal: true

class InAppNotification < ApplicationRecord
  belongs_to :alert_rule
  belongs_to :filing
  validates :filing_id, uniqueness: { scope: :alert_rule_id }
  validates :frequency, inclusion: { in: AlertRuleSetting::FREQUENCIES }
  validates :rule_revision, numericality: { only_integer: true, greater_than: 0 }
  validates :available_at, presence: true

  scope :visible_at, ->(time) {
    joins(:filing).where("in_app_notifications.published_at <= ? AND filings.filed_at <= ?", time, time)
      .where(filings: { parse_status: "parsed", form_type: Filing::SEC_INGEST_TYPES })
  }
end
