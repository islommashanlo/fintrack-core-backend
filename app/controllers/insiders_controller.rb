# frozen_string_literal: true

class InsidersController < ApplicationController
  allow_unauthenticated_access

  def show
    profile = InsiderProfile.new(insider_cik: params[:cik])
    raise ActiveRecord::RecordNotFound if profile.name.blank?

    @insider_cik = params[:cik]
    @insider_name = profile.name
    @summary = profile.summary
    @transactions = profile.transactions(limit: 40)
    @issuer_activity = profile.issuer_activity(days: 730, limit: 12)
  end
end
