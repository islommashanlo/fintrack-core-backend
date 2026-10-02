# frozen_string_literal: true

class MaterializeInstitutionalPositionDiffsJob < ApplicationJob
  queue_as :default

  def perform(institutional_filer_id, period_of_report = nil)
    InstitutionalPositionDiffMaterializer.call(institutional_filer_id:, period_of_report:)
  end
end
