# frozen_string_literal: true

class PushSubscription < ApplicationRecord
  belongs_to :user
  belongs_to :session

  validates :endpoint_digest, presence: true, uniqueness: true, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :endpoint_origin, :encrypted_payload, :consented_at, presence: true
  validate do
    errors.add(:session, "must belong to the account") if session && session.user_id != user_id
  end

  attr_readonly :user_id, :endpoint_digest

  def active_at?(time)
    session.created_at > time - Session::LIFETIME && (expires_at.nil? || expires_at > time)
  end
end
