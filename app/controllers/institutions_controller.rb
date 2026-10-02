# frozen_string_literal: true

class InstitutionsController < ApplicationController
  def show
    @institution = InstitutionalFiler.find_by!(cik: params[:cik])
    profile = InstitutionalProfile.new(institutional_filer: @institution)

    @latest_report = profile.latest_report
    @holdings = profile.top_holdings(limit: 24)
    @changes = profile.position_changes(limit: 12)
  end
end
