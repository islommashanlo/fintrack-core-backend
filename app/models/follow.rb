# frozen_string_literal: true

class Follow < ApplicationRecord
  TARGET_TYPES = %w[Insider InstitutionalFiler Ticker].freeze

  belongs_to :user
  has_one :alert_rule, dependent: :destroy

  after_create :create_default_alert_rule

  validates :target_type, inclusion: { in: TARGET_TYPES }
  validates :target_key, presence: true
  validates :target_key, uniqueness: { scope: %i[user_id target_type] }

  private

  def create_default_alert_rule
    create_alert_rule!(event_type: "new_filing", channel: "email")
  end
end
