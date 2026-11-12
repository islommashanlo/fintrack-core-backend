# frozen_string_literal: true

class OauthIdentity < ApplicationRecord
  belongs_to :user
  validates :provider, inclusion: { in: %w[google] }, uniqueness: { scope: :user_id }
  validates :subject, presence: true, length: { maximum: 255 }, uniqueness: { scope: :provider }
  attr_readonly :user_id, :provider, :subject
end
