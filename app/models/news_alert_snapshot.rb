# frozen_string_literal: true

class NewsAlertSnapshot < ApplicationRecord
  belongs_to :news_item
  belongs_to :news_mention
  has_many :in_app_notifications, dependent: :restrict_with_exception
  has_many :alert_deliveries, dependent: :restrict_with_exception

  def readonly?
    persisted?
  end
end
