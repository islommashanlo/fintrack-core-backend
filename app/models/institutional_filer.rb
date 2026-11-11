# frozen_string_literal: true

class InstitutionalFiler < ApplicationRecord
  has_many :news_mentions, as: :entity, dependent: :restrict_with_exception
  has_many :institutional_reports, dependent: :restrict_with_exception
  has_many :position_diffs, dependent: :restrict_with_exception

  validates :cik, presence: true, uniqueness: true, format: { with: /\A\d{10}\z/ }
  validates :name, presence: true
end
