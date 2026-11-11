# frozen_string_literal: true

class User < ApplicationRecord
  has_secure_password
  generates_token_for :password_reset, expires_in: 15.minutes do
    Digest::SHA256.hexdigest([ password_digest, email_address ].join("\0"))
  end
  has_many :sessions, dependent: :destroy
  has_many :follows, dependent: :destroy
  has_many :alert_rules, through: :follows
  has_many :alert_deliveries, through: :alert_rules
  has_one :notification_preference, dependent: :destroy
  has_one :user_preference, dependent: :destroy
  has_many :saved_screens, dependent: :delete_all
  has_many :billing_customers, dependent: :nullify
  has_many :billing_checkouts, dependent: :delete_all
  has_many :alert_event_states, dependent: :delete_all
  has_many :alert_digest_batches, dependent: :restrict_with_exception

  normalizes :email_address, with: ->(e) { e.strip.downcase }

  validates :email_address, presence: true, uniqueness: true
  validates :email_address, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
  validates :password, length: { minimum: 8 }, allow_nil: true
end
