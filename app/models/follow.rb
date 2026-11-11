# frozen_string_literal: true

class Follow < ApplicationRecord
  TARGET_TYPES = %w[Insider InstitutionalFiler Ticker].freeze

  belongs_to :user
  has_one :alert_rule, dependent: :destroy
  attr_accessor :skip_default_alert_rule

  after_create :create_default_alert_rule, unless: :skip_default_alert_rule
  before_create { self.followed_at ||= created_at || Time.current }

  validates :target_type, inclusion: { in: TARGET_TYPES }
  validates :target_key, presence: true
  validates :target_key, uniqueness: { scope: %i[user_id target_type] }
  scope :current, -> { where(removed_at: nil) }

  private

  def create_default_alert_rule
    user.with_lock do
      limit = PlanCatalog.limit_for(user, :alert_rules)
      create_alert_rule!(event_type: "new_filing", channel: "email", active: false) unless limit && user.alert_rules.retained.count >= limit
    end
  end
end
