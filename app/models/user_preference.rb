# frozen_string_literal: true

class UserPreference < ApplicationRecord
  THEMES = %w[system light dark].freeze
  DASHBOARD_LAYOUTS = %w[split focus columns].freeze

  belongs_to :user

  validates :user_id, uniqueness: true
  validates :theme, inclusion: { in: THEMES }
  validates :dashboard_layout, inclusion: { in: DASHBOARD_LAYOUTS }
end
