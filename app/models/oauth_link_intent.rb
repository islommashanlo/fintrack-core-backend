# frozen_string_literal: true

class OauthLinkIntent < ApplicationRecord
  belongs_to :session
  validates :session_id, uniqueness: true
  validates :state_digest, :nonce_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :expires_at, presence: true
end
