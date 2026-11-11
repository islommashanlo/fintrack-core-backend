# frozen_string_literal: true

class FilingExplanation < ApplicationRecord
  belongs_to :filing

  validates :source_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :prompt_version, :provider_key, :model, :body, :generated_at, presence: true
  validates :generation_method, inclusion: { in: %w[template provider] }
  validates :body, length: { maximum: 30_000 }
  validate :factual_language

  private

  def factual_language
    if Policy::BannedLanguageScan.new.scan_text([ body, model ].join("\n")).any?
      errors.add(:body, "contains unsupported language")
    end
  end
end
