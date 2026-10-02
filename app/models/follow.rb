# frozen_string_literal: true

class Follow < ApplicationRecord
  TARGET_TYPES = %w[Insider InstitutionalFiler Ticker].freeze

  belongs_to :user

  validates :target_type, inclusion: { in: TARGET_TYPES }
  validates :target_key, presence: true
  validates :target_key, uniqueness: { scope: %i[user_id target_type] }
end
