# frozen_string_literal: true

class User < ApplicationRecord
  # Include default devise modules. Others available are:
  # :confirmable, :lockable, :timeoutable, :trackable and :omniauthable
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable, :jwt_authenticatable, jwt_revocation_strategy: self

  self.table_name = 'users'

  # Role management
  rolify

  has_many :alert_subscriptions, dependent: :destroy

  # Set default role after user creation
  after_create :assign_default_role

  def assign_default_role
    add_role(:user) if roles.blank?
  end

  def admin?
    has_role?(:admin)
  end

  def generate_jwt_token
    payload = {
      user_id: id,
      email: email,
      roles: roles.pluck(:name),
      exp: 24.hours.from_now.to_i
    }
    JWT.encode(payload, ENV.fetch('DEVISE_JWT_SECRET_KEY', 'your-super-secret-jwt-key-change-this-in-production'),
               'HS256')
  end
end
