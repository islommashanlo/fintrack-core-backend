# frozen_string_literal: true

class NewsMention < ApplicationRecord
  NATURAL_KEY = %i[news_item_id entity_type entity_id role].freeze

  belongs_to :news_item
  belongs_to :entity, polymorphic: true

  has_many :news_alert_snapshots, dependent: :restrict_with_exception

  validates :entity_type, inclusion: { in: %w[Filer InstitutionalFiler] }
  validates :role, inclusion: { in: %w[issuer fund person] }
  validates :role, uniqueness: { scope: %i[news_item_id entity_type entity_id] }
  validates :observed_at, presence: true
  validate :canonical_role

  attr_readonly :news_item_id, :entity_type, :entity_id, :role, :observed_at

  private

  def canonical_role
    valid = case role
    when "fund" then entity_type == "InstitutionalFiler" && entity.is_a?(InstitutionalFiler)
    when "issuer" then entity_type == "Filer" && entity.is_a?(Filer) && entity.filer_type == "issuer"
    when "person" then entity_type == "Filer" && entity.is_a?(Filer) && entity.filer_type == "insider"
    end
    errors.add(:entity, "does not match the canonical role") unless valid
  end
end
