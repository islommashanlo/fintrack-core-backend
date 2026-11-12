# frozen_string_literal: true

class NewsItem < ApplicationRecord
  KINDS = %w[news press_release other].freeze
  CONTENT_FIELDS = %i[source title url published_at kind].freeze
  NATURAL_KEY = %i[provider provider_item_id].freeze

  has_many :in_app_notifications, dependent: :restrict_with_exception
  has_many :news_mentions, dependent: :restrict_with_exception

  has_many :news_alert_snapshots, dependent: :restrict_with_exception

  validates :provider, format: { with: /\A[a-z][a-z0-9_]{0,39}\z/ }
  validates :provider_item_id, presence: true, length: { maximum: 200 }, uniqueness: { scope: :provider }
  validates :source, presence: true, length: { maximum: 200 }
  validates :title, presence: true, length: { maximum: 500 }
  validates :url, presence: true, length: { maximum: 2048 }
  validates :published_at, :observed_at, presence: true
  validates :kind, inclusion: { in: KINDS }
  validates :suppression_reason, inclusion: { in: %w[restricted_language markup], allow_nil: true }

  scope :publishable, -> { where(suppression_reason: nil) }

  attr_readonly :provider, :provider_item_id, *CONTENT_FIELDS, :observed_at, :suppression_reason
end
