# frozen_string_literal: true

class InsiderClusterSnapshot < ApplicationRecord
  belongs_to :primary_filing, class_name: "Filing"
  has_many :in_app_notifications, dependent: :restrict_with_exception
  has_many :alert_deliveries, dependent: :restrict_with_exception

  # A snapshot is source evidence; new membership produces a new event key.
  def readonly?
    persisted?
  end
end
