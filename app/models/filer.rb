# frozen_string_literal: true

class Filer < ApplicationRecord
  TYPES = %w[insider issuer].freeze

  validates :cik, presence: true, uniqueness: true, format: { with: /\A\d{10}\z/ }
  validates :name, presence: true
  validates :filer_type, inclusion: { in: TYPES }
end
