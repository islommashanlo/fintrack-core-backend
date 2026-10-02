# frozen_string_literal: true

class Security < ApplicationRecord
  SOURCES = %w[openfigi].freeze

  has_many :cusip_security_mappings, dependent: :restrict_with_exception

  validates :figi, presence: true, uniqueness: true
  validates :source, inclusion: { in: SOURCES }
end
