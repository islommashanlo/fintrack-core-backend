# frozen_string_literal: true

class SavedScreen < ApplicationRecord
  belongs_to :user

  normalizes :name, with: ->(value) { value.strip }
  before_validation :normalize_definition

  validates :name, presence: true, length: { maximum: 100 }, uniqueness: { scope: :user_id, case_sensitive: false }
  validate :factual_name

  def definition
    { "entity" => entity, "filters" => filters, "sort" => sort }.tap do |result|
      result["window_days"] = window_days unless window_days.nil?
    end
  end

  private

  def normalize_definition
    normalized = SavedScreenDefinition.normalize(definition)
    assign_attributes(normalized)
  rescue Api::V1::InvalidParameter
    errors.add(:base, "Invalid screen definition")
  end

  def factual_name
    if name&.match?(/[[:cntrl:]]/) || Policy::BannedLanguageScan.new.scan_text(name).any?
      errors.add(:name, "must use factual language without control characters")
    end
  end
end
