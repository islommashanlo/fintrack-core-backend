# frozen_string_literal: true

class InstitutionalChangeSnapshot < ApplicationRecord
  belongs_to :institutional_filer
  belongs_to :primary_filing, class_name: "Filing"
  has_many :in_app_notifications, dependent: :restrict_with_exception
  has_many :alert_deliveries, dependent: :restrict_with_exception

  def readonly?
    persisted?
  end
end
