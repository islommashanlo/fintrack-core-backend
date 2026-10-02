# frozen_string_literal: true

class User < ApplicationRecord
  has_secure_password
  has_many :sessions, dependent: :destroy
  has_many :follows, dependent: :destroy

  normalizes :email_address, with: ->(e) { e.strip.downcase }

  validates :email_address, presence: true, uniqueness: true
  validates :password, length: { minimum: 8 }, allow_nil: true
end
